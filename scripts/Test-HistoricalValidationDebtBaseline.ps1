param(
    [switch]$SelfTest,
    [string]$EvidenceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceHistoricalValidationDebtBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceHistoricalValidationDebtPhaseRunner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/ExternalOwnerAuthorization.psm1') -Force

function Assert-HistoricalDebt {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Historical validation-debt self-test failed: $Message" }
}

function Assert-HistoricalDebtRejected {
    param([scriptblock]$Action,[string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-HistoricalDebt $rejected $Message
}

function Copy-HistoricalDebtValue {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String)
}

function Write-HistoricalDebtJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (ConvertTo-MorphospaceCanonicalJson -Value $Value) + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-HistoricalDebtLockFingerprint {
    param([object]$Lock)
    $copy = Copy-HistoricalDebtValue $Lock
    $copy.lock_fingerprint = '0' * 64
    return Get-MorphospaceCanonicalJsonSha256 -Value $copy
}

function Get-HistoricalDebtWorkflowCapture {
    param(
        [string]$Workspace,
        [string]$MapPath,
        [int]$Sequence,
        [string]$PhaseId
    )
    $hostPath = [Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($hostPath) -or -not [IO.File]::Exists($hostPath)) { $hostPath = (Get-Command pwsh -ErrorAction Stop).Source }
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-RepoRoot',$repoRoot,'-WorkspaceRoot',$Workspace,'-RepositoryMapPath',$MapPath)) { $arguments.Add($argument) | Out-Null }
    # This focused debt test validates the complete synthetic project history
    # without replaying the unrelated owner self-test aggregate. The production
    # baseline action retains its ordinary full cold capture.
    $arguments.Add('-SkipOwnerSelfTests') | Out-Null
    $arguments.Add('-EmitHistoricalValidationDebtCapture') | Out-Null
    $childArguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $repoRoot 'scripts/Test-WorkflowContracts.ps1')) + @($arguments.ToArray())
    $phase = Invoke-MorphospaceHistoricalDebtChildPhase -EvidenceRoot $EvidenceRoot -Sequence $Sequence -PhaseId $PhaseId -FilePath $hostPath -Arguments $childArguments -WorkingDirectory $repoRoot -TimeoutSeconds 300 -ExpectedExitCodes @(0)
    $stdoutBytes = [IO.File]::ReadAllBytes($phase.stdout_path)
    $stderrBytes = [IO.File]::ReadAllBytes($phase.stderr_path)
    $capture = ConvertFrom-HistoricalDebtWorkflowCaptureTransport -Terminal $phase.terminal -StdoutPath $phase.stdout_path -StdoutBytes $stdoutBytes -StderrPath $phase.stderr_path -StderrBytes $stderrBytes -DrainSucceeded $true
    return [pscustomobject]@{ exit_code=[int]$phase.terminal.exit_code;capture=$capture;stdout_bytes=$stdoutBytes;stderr_bytes=$stderrBytes;phase=$phase }
}

function ConvertFrom-HistoricalDebtWorkflowCaptureTransport {
    param(
        [Parameter(Mandatory)][object]$Terminal,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StdoutPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$StdoutBytes,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StderrPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$StderrBytes,
        [Parameter(Mandatory)][bool]$DrainSucceeded
    )
    foreach ($stream in @(
        [pscustomobject]@{name='stdout';path=$StdoutPath;bytes=$StdoutBytes},
        [pscustomobject]@{name='stderr';path=$StderrPath;bytes=$StderrBytes}
    )) {
        $property = $Terminal.PSObject.Properties[[string]$stream.name]
        if ($null -eq $property -or $null -eq $property.Value) {
            throw "Historical-debt workflow capture terminal omits the $([string]$stream.name) evidence reference."
        }
        $reference = $property.Value
        foreach ($required in @('path','sha256','length')) {
            if ($null -eq $reference.PSObject.Properties[$required]) {
                throw "Historical-debt workflow capture terminal $([string]$stream.name) evidence reference omits $required."
            }
        }
        $expectedLeaf = [string]$reference.path
        $observedLeaf = [IO.Path]::GetFileName([string]$stream.path)
        if ([string]::IsNullOrWhiteSpace($expectedLeaf) -or $observedLeaf -cne $expectedLeaf) {
            throw "Historical-debt workflow capture $([string]$stream.name) evidence leaf identity does not match the terminal reference."
        }
        if ([long]$reference.length -ne [long]$stream.bytes.LongLength) {
            throw "Historical-debt workflow capture $([string]$stream.name) evidence length does not match the terminal reference."
        }
        $observedSha256 = Get-MorphospaceSha256Bytes -Bytes $stream.bytes
        if ([string]$reference.sha256 -cne $observedSha256) {
            throw "Historical-debt workflow capture $([string]$stream.name) evidence SHA-256 does not match the terminal reference."
        }
    }
    if (-not $DrainSucceeded -or
        [string]$Terminal.result -cne 'pass' -or
        [string]$Terminal.category -cne 'completed' -or
        [int]$Terminal.exit_code -ne 0 -or
        [bool]$Terminal.timed_out) {
        throw "Historical-debt workflow capture transport failed: result=$([string]$Terminal.result); category=$([string]$Terminal.category); exit=$([string]$Terminal.exit_code); timed_out=$([bool]$Terminal.timed_out); drain_succeeded=$DrainSucceeded"
    }
    if ($StderrBytes.Length -ne 0) { throw 'Historical-debt workflow capture transport emitted stderr failure evidence.' }
    try { $stdout = [Text.UTF8Encoding]::new($false,$true).GetString($StdoutBytes) }
    catch { throw "Historical-debt workflow capture stdout is not strict UTF-8. $($_.Exception.Message)" }
    if ($stdout.IndexOf([char]0) -ge 0) { throw 'Historical-debt workflow capture stdout contains NUL.' }
    $rawLines = @($stdout -split "`n")
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($rawLine in $rawLines) {
        if ($rawLine.Contains("`r") -and -not $rawLine.EndsWith("`r",[StringComparison]::Ordinal)) {
            throw 'Historical-debt workflow capture stdout contains a non-terminal carriage return.'
        }
        $lines.Add($(if($rawLine.EndsWith("`r",[StringComparison]::Ordinal)){$rawLine.Substring(0,$rawLine.Length-1)}else{$rawLine})) | Out-Null
    }
    $prefix = 'historical_validation_debt_capture_base64='
    $markerIndexes = @()
    for ($index=0;$index-lt$lines.Count;$index++) {
        if ($lines[$index].StartsWith($prefix,[StringComparison]::Ordinal)) { $markerIndexes += $index }
        if ($lines[$index] -ceq 'Workflow contract validation failures:' -or $lines[$index].StartsWith('Exception:',[StringComparison]::Ordinal) -or $lines[$index].StartsWith('OperationStopped:',[StringComparison]::Ordinal)) {
            throw 'Historical-debt workflow capture success marker is contradicted by validator failure evidence.'
        }
    }
    if ($markerIndexes.Count -ne 1) { throw 'Historical-debt workflow capture did not emit exactly one envelope.' }
    $lastNonEmpty = -1
    for ($index=$lines.Count-1;$index-ge0;$index--) { if ($lines[$index].Length -gt 0) { $lastNonEmpty=$index;break } }
    if ($markerIndexes[0] -ne $lastNonEmpty) { throw 'Historical-debt workflow capture envelope has trailing output.' }
    $encoded = $lines[$markerIndexes[0]].Substring($prefix.Length)
    if ($encoded.Length -eq 0 -or $encoded.Length % 4 -ne 0 -or $encoded -cnotmatch '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$') {
        throw 'Historical-debt workflow capture envelope is not canonical base64.'
    }
    try { [byte[]]$captureBytes=[Convert]::FromBase64String($encoded) }
    catch { throw "Historical-debt workflow capture envelope base64 is invalid. $($_.Exception.Message)" }
    $capture = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $captureBytes -Context 'historical-debt workflow capture envelope'
    Assert-MorphospaceExactPropertySet $capture @('schema','failure_records') @() 'historical-debt workflow capture envelope'
    if ([string]$capture.schema -cne 'rusty.morphospace.workflow.historical_validation_debt_capture.v1' -or @($capture.failure_records).Count -eq 0) {
        throw 'Historical-debt workflow capture envelope identity or failure set is invalid.'
    }
    [byte[]]$canonicalBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $capture))
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($captureBytes,$canonicalBytes)) {
        throw 'Historical-debt workflow capture envelope bytes are not canonical.'
    }
    return $capture
}

function New-HistoricalDebtTestPolicy {
    param([string]$Root,[Security.Cryptography.RSA]$Rsa)
    $pem = $Rsa.ExportSubjectPublicKeyInfoPem().Replace("`r",'')
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    $sourceSchema = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'schemas/external-owner-authorization-policy-v1.schema.json')
    $schema = $sourceSchema.Replace('mesmerprism-owner-policy-authority-v1','synthetic-owner-authority-v1').Replace('MesmerPrism','SyntheticOwner').Replace('rusty-morphospace-external-owner-authorization:v1','synthetic-external-owner:v1').Replace('e6ceb8c9bb2d3c178b28f15b9cd47ff1229e13584cd9c3b7dec1c2cda2f476e6',$fingerprint)
    $schemaPath = Join-Path $Root 'policy.schema.json'
    $policyPath = Join-Path $Root 'policy.json'
    [IO.File]::WriteAllText($schemaPath, $schema, [Text.UTF8Encoding]::new($false))
    $policy = [ordered]@{
        schema='rusty.morphospace.workflow.external_owner_authorization_policy.v1'
        issuer_id='synthetic-owner-authority-v1';owner_login='SyntheticOwner';comment_marker='synthetic-external-owner:v1'
        max_authorization_age_seconds=86400;max_future_skew_seconds=300;maximum_comments=100;maximum_response_bytes=1048576;maximum_comment_bytes=65536
        public_key_spki_sha256=$fingerprint;public_key_pem=$pem
    }
    Write-HistoricalDebtJson $policyPath $policy
    return [pscustomobject]@{path=$policyPath;schema=$schemaPath;fingerprint=$fingerprint;document=$policy}
}

function Write-HistoricalDebtAuthorization {
    param(
        [string]$Workspace,[Security.Cryptography.RSA]$Rsa,[object]$Policy,
        [datetimeoffset]$Now,[scriptblock]$PayloadMutation = $null,
        [string]$BaselineId = 'synthetic-debt-0001',
        [string]$AuthorizationId = 'synthetic-authorization-0001',
        [string]$AuditId = 'synthetic-audit-0001'
    )
    $baselinePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath "receipts/historical-validation-debt/$BaselineId/baseline.json" -RequireLeaf
    $baselineBytes = [IO.File]::ReadAllBytes($baselinePath)
    $baseline = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineBytes -Context 'synthetic historical-debt baseline'
    $payload = New-MorphospaceHistoricalValidationDebtAuthorizationPayload `
        -Baseline $baseline -BaselineSha256 (Get-MorphospaceSha256Bytes -Bytes $baselineBytes) `
        -AuthorizationId $AuthorizationId -AuditId $AuditId `
        -IssuedAt $Now.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") `
        -ExpiresAt $Now.AddHours(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") `
        -IssuerId ([string]$Policy.document.issuer_id)
    if ($null -ne $PayloadMutation) { & $PayloadMutation $payload }
    [byte[]]$canonical = Get-CanonicalAuthorizationBytes -Payload $payload
    [byte[]]$signature = $Rsa.SignData($canonical,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
    $document = [ordered]@{
        schema='rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1'
        payload=$payload
        signature=[ordered]@{algorithm='RSA-PSS-SHA256';public_key_spki_sha256=[string]$Policy.fingerprint;value_base64=[Convert]::ToBase64String($signature)}
    }
    Write-HistoricalDebtJson (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath "receipts/historical-validation-debt/$BaselineId/authorization.json") $document
}

function New-HistoricalDebtPeerBaseline {
    param([string]$Workspace,[string]$BaselineId)
    $sourcePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath 'receipts/historical-validation-debt/synthetic-debt-0001/baseline.json' -RequireLeaf
    $peer = Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([IO.File]::ReadAllBytes($sourcePath)) -Context 'synthetic source baseline')
    $peer.baseline_id = $BaselineId
    $peer.authorization.path = "receipts/historical-validation-debt/$BaselineId/authorization.json"
    Write-HistoricalDebtJson (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $Workspace -RelativePath "receipts/historical-validation-debt/$BaselineId/baseline.json") $peer
}

function Invoke-HistoricalDebtBaselineVerifier {
    param([string]$Workspace,[string]$MapPath,[object[]]$Records,[object]$Policy,[datetimeoffset]$Now)
    return Test-MorphospaceHistoricalValidationDebtBaseline `
        -WorkspaceRoot $Workspace -RepoRoot $repoRoot -RepositoryMapPath $MapPath `
        -BaselinePath 'receipts/historical-validation-debt/synthetic-debt-0001/baseline.json' `
        -FailureRecords $Records -PolicyPath $Policy.path -PolicySchemaPath $Policy.schema -Now $Now
}

function New-HistoricalDebtUnit {
    param([string]$UnitId,[string]$Status,[bool]$Historical)
    $skills = if ($Historical) {
        @(
            [ordered]@{surface_kind='skill';path='<skills-root>/rusty-morphospace/SKILL.md';owner='workflow-maintainer';change_reason='Historical instruction record.';action='update';status='complete';validation='Historical fixture.';skill_id='rusty-morphospace'},
            [ordered]@{surface_kind='skill';path='<skills-root>/system-engineering/SKILL.md';owner='workflow-maintainer';change_reason='Historical instruction record.';action='update';status='complete';validation='Historical fixture.';skill_id='system-engineering'}
        )
    } else {
        @(
            [ordered]@{surface_kind='skill';path='<skills-root>/rusty-morphospace/SKILL.md';owner='workflow-maintainer';change_reason='Exact lifecycle-routed skill review.';action='review-no-change';status='complete';validation='Synthetic completed review.';skill_id='rusty-morphospace'},
            [ordered]@{surface_kind='skill';path='<skills-root>/system-engineering/SKILL.md';owner='workflow-maintainer';change_reason='Exact lifecycle-routed skill review.';action='review-no-change';status='complete';validation='Synthetic completed review.';skill_id='system-engineering'}
        )
    }
    return [ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id=$UnitId;project_id='synthetic-debt-project';status=$Status
        objective=if($Historical){'Retained terminal historical fixture.'}else{'Corrected active feature fixture with exact routed reviews.'}
        architecture_decision=[ordered]@{selected='Retain the bounded synthetic feature contract.';material_advance='Demonstrate current feature validation without changing historical debt.';deferred='Source, device, and remote operations remain outside this fixture.';deferred_reason='This public fixture validates only workflow contracts.'}
        work_mode='feature';guard_profile='locked';change_categories=@('implementation','authority','validation','public-private-boundary')
        instruction_impact='update'
        instruction_surfaces=@(
            [ordered]@{surface_kind='agents';path='<repo-root>/AGENTS.md';owner='workflow-owner';change_reason='Required instruction entrypoint.';action='update';status='complete';validation='Synthetic fixture.';skill_id=$null},
            [ordered]@{surface_kind='readme';path='<repo-root>/README.md';owner='workflow-owner';change_reason='Required instruction router.';action='update';status='complete';validation='Synthetic fixture.';skill_id=$null}
        ) + $skills
        instruction_none_justification=$null;prerequisites=@();allowed_repositories=@([ordered]@{repo_id='project-shell';allowed_paths=@('src/','morphospace/')})
        non_scope=@('Private projects.','Devices.','Remote operations.');acceptance=@([ordered]@{acceptance_id='synthetic-contract';proof='The synthetic workflow contract validates.';command='synthetic-acceptance'})
        risk_tier='quick';device_requirement='forbidden';validation=@([ordered]@{profile_id='quick';command='synthetic-validation'})
        outputs=@('Synthetic contract evidence.');commit_policy='No source commit is made by this synthetic fixture.';push_checkpoint='none'
    }
}

function Test-HistoricalDebtWorkflowCaptureTransportParser {
    $record=[ordered]@{
        failure_code='historical-unit-contract'
        locus=[ordered]@{kind='historical-unit';unit_id='transport-positive';path='iteration-units/transport-positive.json';raw_sha256='0'*64;canonical_sha256='1'*64}
        message_sha256='2'*64;evidence_sha256='3'*64;record_sha256='4'*64
    }
    $capture=[ordered]@{schema='rusty.morphospace.workflow.historical_validation_debt_capture.v1';failure_records=@($record)}
    [byte[]]$captureBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $capture))
    $marker='historical_validation_debt_capture_base64='+[Convert]::ToBase64String($captureBytes)
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    $stdoutLeaf='219-capture.stdout.log'
    $stderrLeaf='219-capture.stderr.log'
    function New-HistoricalDebtTestTransportTerminal {
        param(
            [Parameter(Mandatory)][string]$Result,
            [Parameter(Mandatory)][string]$Category,
            [AllowNull()][object]$ExitCode,
            [Parameter(Mandatory)][bool]$TimedOut,
            [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$StdoutBytes,
            [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$StderrBytes
        )
        return [pscustomobject]@{
            result=$Result;category=$Category;exit_code=$ExitCode;timed_out=$TimedOut
            stdout=[pscustomobject]@{path=$stdoutLeaf;sha256=Get-MorphospaceSha256Bytes -Bytes $StdoutBytes;length=[long]$StdoutBytes.LongLength}
            stderr=[pscustomobject]@{path=$stderrLeaf;sha256=Get-MorphospaceSha256Bytes -Bytes $StderrBytes;length=[long]$StderrBytes.LongLength}
        }
    }
    function ConvertFrom-HistoricalDebtTestTransport {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$StdoutBytes,
            [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$StderrBytes,
            [string]$Result='pass',
            [string]$Category='completed',
            [AllowNull()][object]$ExitCode=0,
            [bool]$TimedOut=$false,
            [bool]$DrainSucceeded=$true
        )
        $boundTerminal=New-HistoricalDebtTestTransportTerminal -Result $Result -Category $Category -ExitCode $ExitCode -TimedOut $TimedOut -StdoutBytes $StdoutBytes -StderrBytes $StderrBytes
        return ConvertFrom-HistoricalDebtWorkflowCaptureTransport -Terminal $boundTerminal -StdoutPath $stdoutLeaf -StdoutBytes $StdoutBytes -StderrPath $stderrLeaf -StderrBytes $StderrBytes -DrainSucceeded $DrainSucceeded
    }
    $emptyBytes=[byte[]]::new(0)
    $positiveLfBytes=$encoding.GetBytes("bounded-prelude`n$marker`n")
    $positiveLf=ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $positiveLfBytes -StderrBytes $emptyBytes
    Assert-HistoricalDebt ([string]$positiveLf.schema -ceq [string]$capture.schema -and @($positiveLf.failure_records).Count -eq 1) 'A valid LF capture with one empty trailing record was rejected.'
    $positiveCrlf=ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $encoding.GetBytes("bounded-prelude`r`n$marker`r`n") -StderrBytes $emptyBytes
    Assert-HistoricalDebt ([string]$positiveCrlf.schema -ceq [string]$capture.schema -and @($positiveCrlf.failure_records).Count -eq 1) 'A valid CRLF capture with one empty trailing record was rejected.'
    $positiveFinal=ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $encoding.GetBytes($marker) -StderrBytes $emptyBytes
    Assert-HistoricalDebt ([string]$positiveFinal.schema -ceq [string]$capture.schema -and @($positiveFinal.failure_records).Count -eq 1) 'One final capture envelope without a trailing record was rejected.'

    $validBytes=$encoding.GetBytes("$marker`n")
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $validBytes -StderrBytes $emptyBytes -ExitCode 1 } 'A nonzero capture transport was accepted.'
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $validBytes -StderrBytes $emptyBytes -Result 'fail' -Category 'timeout' -ExitCode -1 -TimedOut $true } 'A timed-out capture transport was accepted.'
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $emptyBytes -StderrBytes $emptyBytes -Result 'fail' -Category 'process-start-fail' -ExitCode $null } 'A failed capture launch was accepted.'
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $validBytes -StderrBytes $emptyBytes -DrainSucceeded $false } 'A capture stream drain failure was accepted.'
    $stderrFailureBytes=$encoding.GetBytes("validator failure`n")
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $validBytes -StderrBytes $stderrFailureBytes } 'A success marker accompanied by stderr failure evidence was accepted.'
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $encoding.GetBytes("$marker`n$marker`n") -StderrBytes $emptyBytes } 'Duplicate capture envelopes were accepted.'
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $encoding.GetBytes("$marker`ntrailing-output`n") -StderrBytes $emptyBytes } 'Trailing capture output was accepted.'
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $encoding.GetBytes("historical_validation_debt_capture_base64=%%%=`n") -StderrBytes $emptyBytes } 'Malformed capture base64 was accepted.'
    $malformedPayload=[Convert]::ToBase64String($encoding.GetBytes('{}'))
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $encoding.GetBytes("historical_validation_debt_capture_base64=$malformedPayload`n") -StderrBytes $emptyBytes } 'Malformed capture envelope JSON was accepted.'
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtTestTransport -StdoutBytes $encoding.GetBytes("Workflow contract validation failures:`n$marker`n") -StderrBytes $emptyBytes } 'A success marker contradicted by validator failure output was accepted.'

    $wrongStdoutHash=New-HistoricalDebtTestTransportTerminal -Result 'pass' -Category 'completed' -ExitCode 0 -TimedOut $false -StdoutBytes $validBytes -StderrBytes $emptyBytes
    $wrongStdoutHash.stdout.sha256='0'*64
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtWorkflowCaptureTransport -Terminal $wrongStdoutHash -StdoutPath $stdoutLeaf -StdoutBytes $validBytes -StderrPath $stderrLeaf -StderrBytes $emptyBytes -DrainSucceeded $true } 'Valid-looking capture bytes with the wrong terminal stdout hash were accepted.'
    $wrongStdoutLength=New-HistoricalDebtTestTransportTerminal -Result 'pass' -Category 'completed' -ExitCode 0 -TimedOut $false -StdoutBytes $validBytes -StderrBytes $emptyBytes
    $wrongStdoutLength.stdout.length=[long]$validBytes.LongLength+1
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtWorkflowCaptureTransport -Terminal $wrongStdoutLength -StdoutPath $stdoutLeaf -StdoutBytes $validBytes -StderrPath $stderrLeaf -StderrBytes $emptyBytes -DrainSucceeded $true } 'Valid-looking capture bytes with the wrong terminal stdout length were accepted.'
    $wrongStderrLeaf=New-HistoricalDebtTestTransportTerminal -Result 'pass' -Category 'completed' -ExitCode 0 -TimedOut $false -StdoutBytes $validBytes -StderrBytes $emptyBytes
    $wrongStderrLeaf.stderr.path='219-other.stderr.log'
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtWorkflowCaptureTransport -Terminal $wrongStderrLeaf -StdoutPath $stdoutLeaf -StdoutBytes $validBytes -StderrPath $stderrLeaf -StderrBytes $emptyBytes -DrainSucceeded $true } 'A mismatched terminal stderr leaf identity was accepted.'
    $wrongStderrHash=New-HistoricalDebtTestTransportTerminal -Result 'pass' -Category 'completed' -ExitCode 0 -TimedOut $false -StdoutBytes $validBytes -StderrBytes $emptyBytes
    $wrongStderrHash.stderr.sha256='0'*64
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtWorkflowCaptureTransport -Terminal $wrongStderrHash -StdoutPath $stdoutLeaf -StdoutBytes $validBytes -StderrPath $stderrLeaf -StderrBytes $emptyBytes -DrainSucceeded $true } 'A mismatched terminal stderr SHA-256 was accepted.'
    $wrongStderrLength=New-HistoricalDebtTestTransportTerminal -Result 'pass' -Category 'completed' -ExitCode 0 -TimedOut $false -StdoutBytes $validBytes -StderrBytes $emptyBytes
    $wrongStderrLength.stderr.length=1
    Assert-HistoricalDebtRejected { ConvertFrom-HistoricalDebtWorkflowCaptureTransport -Terminal $wrongStderrLength -StdoutPath $stdoutLeaf -StdoutBytes $validBytes -StderrPath $stderrLeaf -StderrBytes $emptyBytes -DrainSucceeded $true } 'A mismatched terminal stderr length was accepted.'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('historical-validation-debt-' + [guid]::NewGuid().ToString('N'))
if (-not $EvidenceRoot) {
    $EvidenceRoot = Join-Path $repoRoot ('local/validation/historical-validation-debt-' + [guid]::NewGuid().ToString('N'))
}
$EvidenceRoot = Initialize-MorphospaceHistoricalDebtEvidenceSession -EvidenceRoot $EvidenceRoot
$rsa = [Security.Cryptography.RSA]::Create(3072)
try {
    Test-HistoricalDebtWorkflowCaptureTransportParser
    Write-Output 'Historical validation-debt capture transport parser tests passed: terminal stream identity/hash/length and exit/drain/stderr/cardinality/trailing/base64/envelope/contradiction damage rejected.'
    $workspace = Join-Path $temp 'workspace'
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'module-candidates')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'promotion-reviews')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null
    $ownerRoot = Join-Path $temp 'owner'; [IO.Directory]::CreateDirectory($ownerRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $ownerRoot 'AGENTS.md'),'# Synthetic agent surface' + "`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $ownerRoot 'README.md'),'# Synthetic router surface' + "`n",[Text.UTF8Encoding]::new($false))

    $project = [ordered]@{
        schema='rusty.morphospace.workflow.project_spec.v2';project_id='synthetic-debt-project';revision=1;owner='workflow-owner';purpose='Public synthetic fixture for immutable historical validation debt.'
        activation_model=[ordered]@{default='disabled';unlisted_modules='inert';runtime_rule='selected-lock-and-runtime-input'}
        composition=[ordered]@{selected_features=@();denied_features=@();selected_modules=@();denied_modules=@();allowed_permissions=@();denied_permissions=@();data_classes=@()}
        authority_map=@([ordered]@{parameter='project.composition';owner='workflow-owner';adapters=@()})
        repositories=@([ordered]@{repo_id='project-shell';role='application';path='<repo-root>';allowed_paths=@('src/','morphospace/')})
        modules=@();non_scope=@('Private data.','Devices.','Remote operations.');validation_profiles=@([ordered]@{profile_id='quick';commands=@('synthetic-validation')})
        acceptance_profiles=@([ordered]@{profile_id='quick';commands=@('synthetic-acceptance')})
        release_policy=[ordered]@{versioning='fixture';commit_policy='Fixture only.';push_checkpoint='none';source_first=$true;planning_last=$true;force_push_allowed=$false}
        public_boundary=[ordered]@{mode='public';private_overlay='local/';prohibited_evidence=@('private data')}
    }
    $effects=[ordered]@{permissions=@();services=@();activities=@();queries=@();tools=@();assets=@();shaders=@();native_libraries=@();commands=@();routes=@();streams=@();inputs=@();scenes=@();markers=@()}
    $lock=[ordered]@{schema='rusty.morphospace.workflow.feature_lock.v2';project_id='synthetic-debt-project';project_revision=1;revision=1;generated_at='2026-08-21T00:00:00Z';resolver_version='synthetic-resolver/2';lock_fingerprint='0'*64;default_activation='disabled';activation_rule='selected-lock-and-runtime-input';selected_features=@();denied_features=@();features=@();effect_union=$effects}
    $lock.lock_fingerprint=Get-HistoricalDebtLockFingerprint $lock
    $historical=New-HistoricalDebtUnit -UnitId 'legacy-terminal' -Status 'accepted' -Historical $true
    $historical.commit_policy=''
    $historicalTwo=New-HistoricalDebtUnit -UnitId 'legacy-terminal-two' -Status 'accepted' -Historical $true
    $historicalTwo.commit_policy=''
    $current=New-HistoricalDebtUnit -UnitId 'current-feature' -Status 'active' -Historical $false
    $state=[ordered]@{schema='rusty.morphospace.workflow.workspace_state.v2';project_id='synthetic-debt-project';plan_revision=1;current_unit='current-feature';next_ready_unit=$null;last_event_id='current-feature-claimed-0003';last_accepted_receipt='receipts/legacy-terminal-validation.json';repository_heads=@();repository_checkpoints=@();module_registry=[ordered]@{lock_revision=1;lock_fingerprint=$lock.lock_fingerprint;modules=@()};capability_registry=@();dirty_repositories=@();blockers=@();validation_checkpoint=$null;pending_push_bundle=$null}
    $events=@(
        [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='legacy-terminal-accepted-0001';sequence=1;timestamp='2026-08-21T00:00:00Z';project_id='synthetic-debt-project';unit_id='legacy-terminal';event_type='state-transition';summary='Accepted the retained historical fixture.';receipts=@()},
        [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='legacy-terminal-two-accepted-0002';sequence=2;timestamp='2026-08-21T00:01:00Z';project_id='synthetic-debt-project';unit_id='legacy-terminal-two';event_type='state-transition';summary='Accepted the second retained historical fixture.';receipts=@()},
        [ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='current-feature-claimed-0003';sequence=3;timestamp='2026-08-21T00:02:00Z';project_id='synthetic-debt-project';unit_id='current-feature';event_type='state-transition';summary='Claimed the corrected current feature fixture.';receipts=@()}
    )
    Write-HistoricalDebtJson (Join-Path $workspace 'project.spec.json') $project
    Write-HistoricalDebtJson (Join-Path $workspace 'feature.lock.json') $lock
    Write-HistoricalDebtJson (Join-Path $workspace 'workspace.state.json') $state
    Write-HistoricalDebtJson (Join-Path $workspace 'iteration-units/legacy-terminal.json') $historical
    Write-HistoricalDebtJson (Join-Path $workspace 'iteration-units/legacy-terminal-two.json') $historicalTwo
    Write-HistoricalDebtJson (Join-Path $workspace 'iteration-units/current-feature.json') $current
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'), (($events | ForEach-Object { ConvertTo-MorphospaceCanonicalJson $_ }) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $map=[ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@([ordered]@{repo_id='project-shell';path=$ownerRoot;role='planning';aliases=@('repo-root')})}
    $mapPath=Join-Path $temp 'repository-map.json'; Write-HistoricalDebtJson $mapPath $map

    $cold = Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath -Sequence 10 -PhaseId 'current-history-capture'
    Assert-HistoricalDebt ($cold.exit_code -eq 0) 'Focused cold-process current-history capture transport did not complete cleanly.'
    Assert-HistoricalDebt (@($cold.capture.failure_records).Count -eq 2 -and @($cold.capture.failure_records | Where-Object { [string]$_.failure_code -ceq 'historical-unit-contract' }).Count -eq 2) 'Synthetic aggregate did not isolate exactly two terminal historical-unit failures.'
    $records=@($cold.capture.failure_records)

    $baselineEvidencePath = Join-Path $EvidenceRoot 'historical-validation-debt-baseline-evidence.json'
    $baselineEvidencePhase = Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $EvidenceRoot -Sequence 11 -PhaseId 'baseline-evidence' -OwnerPath $PSCommandPath -Action {
        Write-MorphospaceHistoricalDebtBaselineEvidence -EvidencePath $baselineEvidencePath -WorkspaceRoot $workspace -RepoRoot $repoRoot -RepositoryMapPath $mapPath -BaselineId 'synthetic-debt-0001' -FailureRecords $records -CreatedAt ([datetimeoffset]::UtcNow)
    }
    Assert-HistoricalDebt ([string]$baselineEvidencePhase.terminal.result -ceq 'pass') 'Exact baseline evidence was not created.'
    $baselineEvidence = $baselineEvidencePhase.value
    $baselineReusePhase = Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $EvidenceRoot -Sequence 12 -PhaseId 'baseline-reuse' -OwnerPath $PSCommandPath -SuccessCategory 'evidence-reused' -Action {
        Install-MorphospaceHistoricalDebtBaselineEvidence -EvidencePath $baselineEvidencePath -WorkspaceRoot $workspace -RepoRoot $repoRoot -RepositoryMapPath $mapPath -ExpectedEvidenceSha256 ([string]$baselineEvidence.sha256)
    }
    Assert-HistoricalDebt ([string]$baselineReusePhase.terminal.result -ceq 'pass' -and [string]$baselineReusePhase.terminal.category -ceq 'evidence-reused') 'Exact baseline evidence was not reused.'
    $baselineReuse = $baselineReusePhase.value
    Assert-HistoricalDebt ([string]$baselineReuse.source.sha256 -ceq [string]$baselineReuse.installed.sha256 -and [string]$baselineReuse.reuse_key_sha256 -ceq [string]$baselineEvidence.reuse_key_sha256 -and $baselineReuse.authenticated -eq $false -and $baselineReuse.superseded_history_reconstructed -eq $false) 'Baseline evidence reuse did not preserve exact identity and non-authorizing semantics.'
    $baselineRelative='receipts/historical-validation-debt/synthetic-debt-0001/baseline.json'
    Assert-HistoricalDebt ([IO.File]::Exists((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf))) 'Baseline action did not install its exact immutable request.'
    $policy=New-HistoricalDebtTestPolicy -Root $temp -Rsa $rsa
    $now=[datetimeoffset]::UtcNow
    Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    $result=Invoke-HistoricalDebtBaselineVerifier -Workspace $workspace -MapPath $mapPath -Records @($cold.capture.failure_records) -Policy $policy -Now $now
    Assert-HistoricalDebt ([string]$result.status -ceq 'debt-bearing-success' -and [string]$result.current_validation -ceq 'passed' -and $result.historical_debt_present -eq $true -and [int]$result.historical_debt.count -eq 2) 'Exact baseline did not produce an explicit debt-bearing current-validation success.'
    Assert-HistoricalDebt ((ConvertTo-MorphospaceCanonicalJson $result | Test-Json -SchemaFile (Join-Path $repoRoot 'schemas/historical-validation-debt-result-v1.schema.json'))) 'Debt-bearing result failed its closed schema.'
    $resultRelative = "receipts/historical-validation-debt/synthetic-debt-0001/results/$([string]$result.current_unit.raw_sha256).json"
    Write-HistoricalDebtJson (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $resultRelative) $result
    $debtBinding = [pscustomobject][ordered]@{
        baseline = [pscustomobject][ordered]@{role='historical-validation-debt-baseline';path=$baselineRelative;schema='rusty.morphospace.workflow.historical_validation_debt_baseline.v1';sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf)}
        authorization = [pscustomobject][ordered]@{role='historical-validation-debt-authorization';path='receipts/historical-validation-debt/synthetic-debt-0001/authorization.json';schema='rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1';sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'receipts/historical-validation-debt/synthetic-debt-0001/authorization.json' -RequireLeaf)}
        result = [pscustomobject][ordered]@{role='historical-validation-debt-result';path=$resultRelative;schema='rusty.morphospace.workflow.historical_validation_debt_result.v1';sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $resultRelative -RequireLeaf)}
    }
    $boundResult = Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $debtBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now
    Assert-HistoricalDebt ([string]$boundResult.status -ceq 'debt-bearing-success') 'Receipt binding did not revalidate the signed debt-bearing result.'
    New-HistoricalDebtPeerBaseline -Workspace $workspace -BaselineId 'synthetic-debt-0002';Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now -BaselineId 'synthetic-debt-0002' -AuthorizationId 'synthetic-authorization-0001' -AuditId 'synthetic-audit-0002'
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A repeated authorization ID in another signed canonical baseline sibling was accepted.'
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $debtBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'Receipt binding accepted a repeated authorization ID in another signed canonical baseline sibling.'
    [IO.Directory]::Delete((Join-Path $workspace 'receipts/historical-validation-debt/synthetic-debt-0002'), $true)
    New-HistoricalDebtPeerBaseline -Workspace $workspace -BaselineId 'synthetic-debt-0003';Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now -BaselineId 'synthetic-debt-0003' -AuthorizationId 'synthetic-authorization-0003' -AuditId 'synthetic-audit-0001'
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A repeated audit ID in another signed canonical baseline sibling was accepted.'
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $debtBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'Receipt binding accepted a repeated audit ID in another signed canonical baseline sibling.'
    [IO.Directory]::Delete((Join-Path $workspace 'receipts/historical-validation-debt/synthetic-debt-0003'), $true)
    $movedBaselineRelative = 'receipts/historical-validation-debt/relocated-debt-0001/baseline.json';$movedBaselinePath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $movedBaselineRelative;$null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($movedBaselinePath)) -Force;[IO.File]::WriteAllBytes($movedBaselinePath,[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf)));$movedBaselineBinding=Copy-HistoricalDebtValue $debtBinding;$movedBaselineBinding.baseline.path=$movedBaselineRelative
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $movedBaselineBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A valid baseline copied outside its canonical baseline directory was accepted.'
    $movedResultRelative = "receipts/historical-validation-debt/relocated-debt-0001/results/$([string]$result.current_unit.raw_sha256).json";$movedResultPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $movedResultRelative;$null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($movedResultPath)) -Force;[IO.File]::WriteAllBytes($movedResultPath,[IO.File]::ReadAllBytes((Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $resultRelative -RequireLeaf)));$movedResultBinding=Copy-HistoricalDebtValue $debtBinding;$movedResultBinding.result.path=$movedResultRelative
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $movedResultBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A valid result relocated outside its baseline/current-unit path was accepted.'
    [IO.Directory]::Delete((Join-Path $workspace 'receipts/historical-validation-debt/relocated-debt-0001'), $true)
    $resultPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $resultRelative -RequireLeaf;$resultOriginal=[IO.File]::ReadAllBytes($resultPath);$validatorDriftResult=Copy-HistoricalDebtValue $result;$validatorDriftResult.validator_identity_sha256='0'*64;Write-HistoricalDebtJson $resultPath $validatorDriftResult;$validatorDriftBinding=Copy-HistoricalDebtValue $debtBinding;$validatorDriftBinding.result.sha256=Get-MorphospaceFileSha256 $resultPath
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $validatorDriftBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A result with a validator identity differing from its baseline was accepted.'
    [IO.File]::WriteAllBytes($resultPath,$resultOriginal)
    $baselineReceiptPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative -RequireLeaf;$baselineReceiptOriginal=[IO.File]::ReadAllBytes($baselineReceiptPath);$authorizationReceiptPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'receipts/historical-validation-debt/synthetic-debt-0001/authorization.json' -RequireLeaf;$authorizationReceiptOriginal=[IO.File]::ReadAllBytes($authorizationReceiptPath)
    $liveValidatorDriftBaseline=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineReceiptOriginal -Context 'synthetic baseline');$liveValidatorDriftBaseline.validator.identity_sha256='0'*64;Write-HistoricalDebtJson $baselineReceiptPath $liveValidatorDriftBaseline;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    $liveValidatorDriftResult=Copy-HistoricalDebtValue $result;$liveValidatorDriftResult.baseline.sha256=Get-MorphospaceFileSha256 $baselineReceiptPath;$liveValidatorDriftResult.authorization.sha256=Get-MorphospaceFileSha256 $authorizationReceiptPath;$liveValidatorDriftResult.validator_identity_sha256='0'*64;Write-HistoricalDebtJson $resultPath $liveValidatorDriftResult;$liveValidatorDriftBinding=Copy-HistoricalDebtValue $debtBinding;$liveValidatorDriftBinding.baseline.sha256=Get-MorphospaceFileSha256 $baselineReceiptPath;$liveValidatorDriftBinding.authorization.sha256=Get-MorphospaceFileSha256 $authorizationReceiptPath;$liveValidatorDriftBinding.result.sha256=Get-MorphospaceFileSha256 $resultPath
    Assert-HistoricalDebtRejected { Test-MorphospaceHistoricalValidationDebtReceiptBinding -WorkspaceRoot $workspace -Binding $liveValidatorDriftBinding -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A signed result from a validator identity drifting from the live Work Environment validator was accepted.'
    [IO.File]::WriteAllBytes($baselineReceiptPath,$baselineReceiptOriginal);[IO.File]::WriteAllBytes($authorizationReceiptPath,$authorizationReceiptOriginal);[IO.File]::WriteAllBytes($resultPath,$resultOriginal)
    $requiredBinding = Get-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $workspace -CurrentUnit $current -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now
    Assert-HistoricalDebt ((Get-MorphospaceCanonicalJsonSha256 -Value $requiredBinding) -ceq (Get-MorphospaceCanonicalJsonSha256 -Value $debtBinding)) 'The content-addressed ratchet result did not require its exact validation-receipt binding.'
    Assert-HistoricalDebtRejected { Assert-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $workspace -CurrentUnit $current -Receipt ([pscustomobject]@{}) -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A debt-bearing result allowed a validation receipt with no historical-debt binding.'
    $matchingReceipt = [pscustomobject]@{ historical_validation_debt=$debtBinding }
    $null = Assert-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $workspace -CurrentUnit $current -Receipt $matchingReceipt -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now
    $mismatchedReceipt = [pscustomobject]@{ historical_validation_debt=(Copy-HistoricalDebtValue $debtBinding) };$mismatchedReceipt.historical_validation_debt.result.sha256='0'*64
    Assert-HistoricalDebtRejected { Assert-MorphospaceHistoricalValidationDebtReceiptRequirement -WorkspaceRoot $workspace -CurrentUnit $current -Receipt $mismatchedReceipt -PolicyPath $policy.path -PolicySchemaPath $policy.schema -Now $now } 'A mismatched debt-bearing validation-receipt binding was accepted.'

    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($records[1],$records[0]) $policy $now } 'A reversed canonical historical failure set was accepted.'
    $extra=Copy-HistoricalDebtValue $records[0];$extra.message_sha256='1'*64;$extra.evidence_sha256='2'*64;$extra.record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$extra.failure_code;locus=$extra.locus;message_sha256=[string]$extra.message_sha256;evidence_sha256=[string]$extra.evidence_sha256})
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($records + $extra) $policy $now } 'A new post-anchor failure was accepted.'
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @() $policy $now } 'A removed historical failure was accepted.'
    $altered=Copy-HistoricalDebtValue $records[0];$altered.message_sha256='3'*64;$altered.record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$altered.failure_code;locus=$altered.locus;message_sha256=[string]$altered.message_sha256;evidence_sha256=[string]$altered.evidence_sha256})
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($altered) $policy $now } 'An altered normalized message/evidence record was accepted.'
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($records + $records[0]) $policy $now } 'A duplicate historical failure record was accepted.'

    $baselinePath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath $baselineRelative;$baselineOriginal=[IO.File]::ReadAllBytes($baselinePath)
    $baselineDocument=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline'
    $validatorPaths = @($baselineDocument.validator.files | ForEach-Object { [string]$_.path })
    foreach ($requiredValidatorPath in @('scripts/New-HistoricalValidationDebtBaseline.ps1','scripts/Test-WorkflowContracts.ps1','scripts/Test-ExecutedPushReceipt.ps1','scripts/Test-ReleaseCapsule.ps1','scripts/WorkUnitAutomation.psm1','scripts/lib/MorphospaceActiveUnitContractReviewCompatibility.psm1','scripts/lib/MorphospaceBlockedSupersessionTerminalValidation.psm1','scripts/lib/MorphospaceCompletedTransitionSemanticCorrection.psm1','scripts/lib/MorphospaceHistoricalBlockerResolutionIntentBindingCorrection.psm1','scripts/lib/MorphospaceHistoricalUnitCompatibilityProjection.psm1','config/external-owner-authorization.json','schemas/external-owner-authorization-policy-v1.schema.json','manifests/workflow-lifecycle.portable.json','templates/iteration-events.example.jsonl','templates/iteration-events.v2.example.jsonl')) {
        Assert-HistoricalDebt ($validatorPaths -ccontains $requiredValidatorPath) "Validator identity omitted executed dependency '$requiredValidatorPath'."
    }

    $historicalPath=Join-Path $workspace 'iteration-units/legacy-terminal.json';$historicalOriginal=[IO.File]::ReadAllBytes($historicalPath);$nonTerminalHistorical=Copy-HistoricalDebtValue $historical;$nonTerminalHistorical.status='active';Write-HistoricalDebtJson $historicalPath $nonTerminalHistorical
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline covered a non-terminal historical-unit locus.'
    [IO.File]::WriteAllBytes($historicalPath,$historicalOriginal)

    $missingLocus=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$missingLocus.failure_records[0].locus.unit_id='missing-terminal';$missingLocus.failure_records[0].locus.path='iteration-units/missing-terminal.json';$missingLocus.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$missingLocus.failure_records[0].failure_code;locus=$missingLocus.failure_records[0].locus;message_sha256=[string]$missingLocus.failure_records[0].message_sha256;evidence_sha256=[string]$missingLocus.failure_records[0].evidence_sha256});$missingLocus.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($missingLocus.failure_records);Write-HistoricalDebtJson $baselinePath $missingLocus;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($missingLocus.failure_records) $policy $now } 'A baseline covered a nonexistent historical-unit locus.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $unitHashMismatch=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$unitHashMismatch.failure_records[0].locus.raw_sha256='0'*64;$unitHashMismatch.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$unitHashMismatch.failure_records[0].failure_code;locus=$unitHashMismatch.failure_records[0].locus;message_sha256=[string]$unitHashMismatch.failure_records[0].message_sha256;evidence_sha256=[string]$unitHashMismatch.failure_records[0].evidence_sha256});$unitHashMismatch.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($unitHashMismatch.failure_records);Write-HistoricalDebtJson $baselinePath $unitHashMismatch;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($unitHashMismatch.failure_records) $policy $now } 'A baseline covered a historical-unit locus with a mismatched raw hash.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $stateLocusMismatch=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$stateLocusMismatch.failure_records[0].failure_code='legacy-workspace-state-contract';$stateLocusMismatch.failure_records[0].locus=[ordered]@{kind='legacy-workspace-state';path='workspace.state.json';raw_sha256=Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'workspace.state.json' -RequireLeaf);canonical_sha256='0'*64};$stateLocusMismatch.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$stateLocusMismatch.failure_records[0].failure_code;locus=$stateLocusMismatch.failure_records[0].locus;message_sha256=[string]$stateLocusMismatch.failure_records[0].message_sha256;evidence_sha256=[string]$stateLocusMismatch.failure_records[0].evidence_sha256});$stateLocusMismatch.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($stateLocusMismatch.failure_records);Write-HistoricalDebtJson $baselinePath $stateLocusMismatch;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath @($stateLocusMismatch.failure_records) $policy $now } 'A baseline covered legacy workspace-state debt with a canonical hash not frozen by its workspace anchor.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $manifestDrift=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$manifestDrift.validator.files=@($manifestDrift.validator.files|Where-Object{[string]$_.path-cne'scripts/lib/MorphospaceActiveUnitContractReviewCompatibility.psm1'});$manifestCore=[ordered]@{environment_commit=[string]$manifestDrift.validator.environment_commit;environment_tree=[string]$manifestDrift.validator.environment_tree;files=$manifestDrift.validator.files};$manifestDrift.validator.identity_sha256=Get-MorphospaceCanonicalJsonSha256 $manifestCore;Write-HistoricalDebtJson $baselinePath $manifestDrift;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline with an omitted aggregate module digest was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $directScriptDrift=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$directScriptDrift.validator.files=@($directScriptDrift.validator.files|Where-Object{[string]$_.path-cne'scripts/Test-ReleaseCapsule.ps1'});$directScriptCore=[ordered]@{environment_commit=[string]$directScriptDrift.validator.environment_commit;environment_tree=[string]$directScriptDrift.validator.environment_tree;files=$directScriptDrift.validator.files};$directScriptDrift.validator.identity_sha256=Get-MorphospaceCanonicalJsonSha256 $directScriptCore;Write-HistoricalDebtJson $baselinePath $directScriptDrift;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline with an omitted direct aggregate script digest was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $templateDrift=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$templateDrift.validator.files=@($templateDrift.validator.files|Where-Object{[string]$_.path-cne'templates/iteration-events.example.jsonl'});$templateCore=[ordered]@{environment_commit=[string]$templateDrift.validator.environment_commit;environment_tree=[string]$templateDrift.validator.environment_tree;files=$templateDrift.validator.files};$templateDrift.validator.identity_sha256=Get-MorphospaceCanonicalJsonSha256 $templateCore;Write-HistoricalDebtJson $baselinePath $templateDrift;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline with an omitted JSONL aggregate template digest was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $currentPath=Join-Path $workspace 'iteration-units/current-feature.json';$currentOriginal=[IO.File]::ReadAllBytes($currentPath)
    $writableReview=Copy-HistoricalDebtValue $current;$writableReview.allowed_repositories[0].allowed_paths+= '<skills-root>';Write-HistoricalDebtJson $currentPath $writableReview
    $writableCapture=Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath -Sequence 20 -PhaseId 'writable-current-damage'
    Assert-HistoricalDebt ($writableCapture.exit_code -eq 0 -and @($writableCapture.capture.failure_records|Where-Object{[string]$_.failure_code -ceq 'current-unit-contract'}).Count -gt 0) 'A writable current instruction-surface path was classified as historical debt.'
    [IO.File]::WriteAllBytes($currentPath,$currentOriginal)
    $extraSkill=Copy-HistoricalDebtValue $current;$extraSkill.instruction_surfaces+=,[ordered]@{surface_kind='skill';path='<skills-root>/rust-work-graph/SKILL.md';owner='workflow-maintainer';change_reason='Injected non-required review.';action='review-no-change';status='complete';validation='Synthetic damaged fixture.';skill_id='rust-work-graph'};Write-HistoricalDebtJson $currentPath $extraSkill
    $extraSkillCapture=Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath -Sequence 21 -PhaseId 'extra-skill-damage'
    Assert-HistoricalDebt ($extraSkillCapture.exit_code -eq 0 -and @($extraSkillCapture.capture.failure_records|Where-Object{[string]$_.failure_code -ceq 'current-unit-contract'}).Count -gt 0) 'A non-required current skill surface was classified as historical debt.'
    [IO.File]::WriteAllBytes($currentPath,$currentOriginal)

    $historicalTwoPath=Join-Path $workspace 'iteration-units/legacy-terminal-two.json';$historicalTwoOriginal=[IO.File]::ReadAllBytes($historicalTwoPath);$validHistoricalTwo=Copy-HistoricalDebtValue $historicalTwo;$validHistoricalTwo.commit_policy='No source commit is made by this synthetic fixture.';Write-HistoricalDebtJson $historicalTwoPath $validHistoricalTwo
    $unknownHistorical=Copy-HistoricalDebtValue $historical;$unknownHistorical.commit_policy='No source commit is made by this synthetic fixture.';$unknownHistorical.change_categories+= 'unknown-legacy-category';Write-HistoricalDebtJson $historicalPath $unknownHistorical
    $unknownHistoricalCapture=Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath -Sequence 22 -PhaseId 'unknown-history-damage'
    Assert-HistoricalDebt ($unknownHistoricalCapture.exit_code -eq 0 -and @($unknownHistoricalCapture.capture.failure_records|Where-Object{[string]$_.failure_code -ceq 'historical-unit-contract'}).Count -eq 0 -and @($unknownHistoricalCapture.capture.failure_records|Where-Object{[string]$_.failure_code -ceq 'unclassified-contract'}).Count -gt 0) 'An unknown historical change category was classified as baseline-eligible debt.'
    Assert-HistoricalDebtRejected { New-MorphospaceHistoricalValidationDebtBaseline -WorkspaceRoot $workspace -RepoRoot $repoRoot -RepositoryMapPath $mapPath -BaselineId 'synthetic-debt-unknown-category' -FailureRecords @($unknownHistoricalCapture.capture.failure_records) } 'An unknown historical change category was allowed to produce a baseline.'
    [IO.File]::WriteAllBytes($historicalPath,$historicalOriginal);[IO.File]::WriteAllBytes($historicalTwoPath,$historicalTwoOriginal)

    $currentDrift=Copy-HistoricalDebtValue $current;$currentDrift.objective='Rewritten current feature fixture after baseline capture.';Write-HistoricalDebtJson $currentPath $currentDrift
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A current-unit rewrite after baseline capture was accepted.'
    [IO.File]::WriteAllBytes($currentPath,$currentOriginal)
    $noCurrentStatePath=Join-Path $workspace 'workspace.state.json';$noCurrentStateOriginal=[IO.File]::ReadAllBytes($noCurrentStatePath);$noCurrentState=Copy-HistoricalDebtValue $state;$noCurrentState.current_unit=$null;Write-HistoricalDebtJson $noCurrentStatePath $noCurrentState
    Assert-HistoricalDebtRejected { New-MorphospaceHistoricalValidationDebtBaseline -WorkspaceRoot $workspace -RepoRoot $repoRoot -RepositoryMapPath $mapPath -BaselineId 'synthetic-debt-no-current' -FailureRecords $records } 'A baseline was emitted without an exact current active/validating unit.'
    [IO.File]::WriteAllBytes($noCurrentStatePath,$noCurrentStateOriginal)

    $ledgerPath=Join-Path $workspace 'iteration-events.jsonl';$ledgerOriginal=[IO.File]::ReadAllBytes($ledgerPath);$postAnchor=[ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id='current-feature-invalid-0003';sequence=3;timestamp='2026-08-21T00:02:00Z';project_id='wrong-project';unit_id='current-feature';event_type='state-transition';summary='Damaged post-anchor transition.';receipts=@()};[IO.File]::AppendAllText($ledgerPath,(ConvertTo-MorphospaceCanonicalJson $postAnchor)+"`n",[Text.UTF8Encoding]::new($false))
    $baselineAuthorityRoot=Join-Path $workspace 'receipts/historical-validation-debt'
    [string[]]$baselineAuthorityBefore=@(Get-ChildItem -LiteralPath $baselineAuthorityRoot -File -Recurse|ForEach-Object{$relative=[IO.Path]::GetRelativePath($baselineAuthorityRoot,$_.FullName).Replace('\','/');"$relative`t$($_.Length)`t$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())"})
    [Array]::Sort($baselineAuthorityBefore,[StringComparer]::Ordinal)
    $baselineAuthorityBeforeSha=Get-MorphospaceCanonicalJsonSha256 -Value $baselineAuthorityBefore
    $postAnchorRejected=$false;$postAnchorReason=''
    try { $null=Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath -Sequence 23 -PhaseId 'post-anchor-damage' }
    catch { $postAnchorRejected=$true;$postAnchorReason=[string]$_.Exception.Message }
    Assert-HistoricalDebt ($postAnchorRejected -and $postAnchorReason -ceq 'Historical-debt workflow capture transport failed: result=fail; category=code-fail; exit=1; timed_out=False; drain_succeeded=True') 'A damaged post-baseline transition did not fail as an exact drained code-fail transport.'
    $postAnchorTerminalPath=Join-Path $EvidenceRoot '023-post-anchor-damage.terminal.json'
    $postAnchorTerminal=ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([IO.File]::ReadAllBytes($postAnchorTerminalPath)) -Context 'post-anchor damage terminal receipt'
    $postAnchorStartPath=Join-Path $EvidenceRoot ([string]$postAnchorTerminal.start_receipt.path)
    $postAnchorStdoutPath=Join-Path $EvidenceRoot ([string]$postAnchorTerminal.stdout.path)
    $postAnchorStderrPath=Join-Path $EvidenceRoot ([string]$postAnchorTerminal.stderr.path)
    [byte[]]$postAnchorStdoutBytes=[IO.File]::ReadAllBytes($postAnchorStdoutPath);[byte[]]$postAnchorStderrBytes=[IO.File]::ReadAllBytes($postAnchorStderrPath)
    Assert-HistoricalDebt ([string]$postAnchorTerminal.result -ceq 'fail' -and [string]$postAnchorTerminal.category -ceq 'code-fail' -and [int]$postAnchorTerminal.exit_code -eq 1 -and [bool]$postAnchorTerminal.timed_out -eq $false -and [bool]$postAnchorTerminal.child_tree_cleanup.succeeded) 'Post-anchor damage terminal was not typed code-fail/non-timeout with successful cleanup.'
    Assert-HistoricalDebt ((Get-MorphospaceFileSha256 -Path $postAnchorStartPath) -ceq [string]$postAnchorTerminal.start_receipt.sha256 -and [long]([IO.FileInfo]$postAnchorStartPath).Length -eq [long]$postAnchorTerminal.start_receipt.length) 'Post-anchor damage start receipt identity is unbound.'
    Assert-HistoricalDebt ((Get-MorphospaceSha256Bytes -Bytes $postAnchorStdoutBytes) -ceq [string]$postAnchorTerminal.stdout.sha256 -and $postAnchorStdoutBytes.Length -eq [long]$postAnchorTerminal.stdout.length -and (Get-MorphospaceSha256Bytes -Bytes $postAnchorStderrBytes) -ceq [string]$postAnchorTerminal.stderr.sha256 -and $postAnchorStderrBytes.Length -eq [long]$postAnchorTerminal.stderr.length) 'Post-anchor damage raw output evidence does not match its terminal receipt.'
    $postAnchorStdout=[Text.UTF8Encoding]::new($false,$true).GetString($postAnchorStdoutBytes);$postAnchorStderr=[Text.UTF8Encoding]::new($false,$true).GetString($postAnchorStderrBytes)
    Assert-HistoricalDebt ($postAnchorStdout.IndexOf('historical_validation_debt_capture_base64=',[StringComparison]::Ordinal) -lt 0) 'Post-anchor damage emitted a capture envelope.'
    Assert-HistoricalDebt ($postAnchorStdout.Contains('Historical compatibility event sequence does not equal physical order.',[StringComparison]::Ordinal) -and $postAnchorStdout.Contains("event 'current-feature-invalid-0003' project_id does not match.",[StringComparison]::Ordinal) -and $postAnchorStdout.Contains('event sequences must be strictly increasing.',[StringComparison]::Ordinal) -and $postAnchorStderr.Contains('Workflow contract validation failed with 5 error(s).',[StringComparison]::Ordinal)) 'Post-anchor damage terminal reason is not bound to the expected parser/ledger output.'
    [string[]]$baselineAuthorityAfter=@(Get-ChildItem -LiteralPath $baselineAuthorityRoot -File -Recurse|ForEach-Object{$relative=[IO.Path]::GetRelativePath($baselineAuthorityRoot,$_.FullName).Replace('\','/');"$relative`t$($_.Length)`t$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())"})
    [Array]::Sort($baselineAuthorityAfter,[StringComparer]::Ordinal)
    Assert-HistoricalDebt ($baselineAuthorityAfter.Count -eq $baselineAuthorityBefore.Count -and (Get-MorphospaceCanonicalJsonSha256 -Value $baselineAuthorityAfter) -ceq $baselineAuthorityBeforeSha) 'Post-anchor damage emitted or altered baseline authority.'
    [IO.File]::WriteAllBytes($ledgerPath,$ledgerOriginal)

    [IO.File]::WriteAllText($ledgerPath,'not-a-ledger'+"`n",[Text.UTF8Encoding]::new($false))
    Assert-HistoricalDebtRejected { Get-HistoricalDebtWorkflowCapture -Workspace $workspace -MapPath $mapPath -Sequence 24 -PhaseId 'ledger-transport-damage' } 'A validator transport/capture failure was allowed to generate a baseline.'
    [IO.File]::WriteAllBytes($ledgerPath,$ledgerOriginal)

    $statePath=Join-Path $workspace 'workspace.state.json';$stateOriginal=[IO.File]::ReadAllBytes($statePath);$drift=Copy-HistoricalDebtValue $state;$drift.plan_revision=2;Write-HistoricalDebtJson $statePath $drift
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'Planning-state drift before a ledger suffix was accepted.'
    [IO.File]::WriteAllBytes($statePath,$stateOriginal)
    $lockPath=Join-Path $workspace 'feature.lock.json';$lockOriginal=[IO.File]::ReadAllBytes($lockPath);$lockDrift=Copy-HistoricalDebtValue $lock;$lockDrift.revision=2;$lockDrift.lock_fingerprint=Get-HistoricalDebtLockFingerprint $lockDrift;Write-HistoricalDebtJson $lockPath $lockDrift
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'Source-lock drift was accepted.'
    [IO.File]::WriteAllBytes($lockPath,$lockOriginal)
    $mapOriginal=[IO.File]::ReadAllBytes($mapPath);$mapDrift=Copy-HistoricalDebtValue $map;$mapDrift.repositories[0].aliases+= 'scope-drift';Write-HistoricalDebtJson $mapPath $mapDrift
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'Repository-map composition drift was accepted.'
    [IO.File]::WriteAllBytes($mapPath,$mapOriginal)
    $authPath=Resolve-MorphospaceWorkspacePath -WorkspaceRoot $workspace -RelativePath 'receipts/historical-validation-debt/synthetic-debt-0001/authorization.json';$authOriginal=[IO.File]::ReadAllBytes($authPath);$badAuth=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $authOriginal -Context 'synthetic authorization');$badAuth.signature.value_base64=[Convert]::ToBase64String([byte[]](1..200));Write-HistoricalDebtJson $authPath $badAuth
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A malformed external-owner signature was accepted.'
    [IO.File]::WriteAllBytes($authPath,$authOriginal)
    Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now -PayloadMutation { param($payload) $payload.expires_at=$now.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'An expired authorization was accepted.'
    Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now -PayloadMutation { param($payload) $payload.audit_id='short' }
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A malformed/replayed audit identifier was accepted.'
    Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $validatorDrift=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$validatorDrift.validator.environment_commit='0'*40;$core=[ordered]@{environment_commit=$validatorDrift.validator.environment_commit;environment_tree=[string]$validatorDrift.validator.environment_tree;files=$validatorDrift.validator.files};$validatorDrift.validator.identity_sha256=Get-MorphospaceCanonicalJsonSha256 $core;Write-HistoricalDebtJson $baselinePath $validatorDrift;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'Validator commit/tree drift was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $currentAttempt=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$currentAttempt.failure_records[0].locus.unit_id='current-feature';$currentAttempt.failure_records[0].locus.path='iteration-units/current-feature.json';$currentAttempt.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code=[string]$currentAttempt.failure_records[0].failure_code;locus=$currentAttempt.failure_records[0].locus;message_sha256=[string]$currentAttempt.failure_records[0].message_sha256;evidence_sha256=[string]$currentAttempt.failure_records[0].evidence_sha256});$currentAttempt.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($currentAttempt.failure_records);Write-HistoricalDebtJson $baselinePath $currentAttempt;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'A baseline covering the capture current unit was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    $unknownCode=Copy-HistoricalDebtValue (ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineOriginal -Context 'synthetic baseline');$unknownCode.failure_records[0].failure_code='unknown-contract';$unknownCode.failure_records[0].record_sha256=Get-MorphospaceCanonicalJsonSha256 ([ordered]@{failure_code='unknown-contract';locus=$unknownCode.failure_records[0].locus;message_sha256=[string]$unknownCode.failure_records[0].message_sha256;evidence_sha256=[string]$unknownCode.failure_records[0].evidence_sha256});$unknownCode.failure_set.sha256=Get-MorphospaceCanonicalJsonSha256 @($unknownCode.failure_records);Write-HistoricalDebtJson $baselinePath $unknownCode;Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now
    Assert-HistoricalDebtRejected { Invoke-HistoricalDebtBaselineVerifier $workspace $mapPath $records $policy $now } 'An unknown/malformed historical-debt failure code was accepted.'
    [IO.File]::WriteAllBytes($baselinePath,$baselineOriginal);Write-HistoricalDebtAuthorization -Workspace $workspace -Rsa $rsa -Policy $policy -Now $now

    Write-Output ("Historical validation-debt baseline tests passed (phase-aware focused current-history capture, exact debt-evidence reuse key {0}, closed validator manifest, exact ratchet, mandatory signed receipt binding, current-feature success, and altered/new/removed/reordered/duplicate/unknown-category/current/state/source/validator/signature/expiry/audit/transport damage rejection). Evidence root: {1}" -f [string]$baselineReuse.reuse_key_sha256,$EvidenceRoot)
} finally {
    $rsa.Dispose()
    $cleanup = Invoke-MorphospaceHistoricalDebtActionPhase -EvidenceRoot $EvidenceRoot -Sequence 999 -PhaseId 'fixture-cleanup' -OwnerPath $PSCommandPath -SuccessCategory 'fixture-cleanup' -FailureCategory 'fixture-cleanup' -Action {
        if ([IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp,$true) }
        if ([IO.Directory]::Exists($temp)) { throw 'Historical validation-debt fixture still exists after cleanup.' }
        return [pscustomobject]@{cleanup='complete';path=$temp}
    }
    if ([string]$cleanup.terminal.result -cne 'pass') { throw 'Historical validation-debt fixture cleanup failed; see the typed cleanup phase receipt.' }
}
