param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot "lib/ExternalOwnerAuthorization.psm1") -Force
$schema = Join-Path $root "schemas/external-owner-authorization-v1.schema.json"
$policySchemaSource = Join-Path $root "schemas/external-owner-authorization-policy-v1.schema.json"
$now = [datetimeoffset]::Parse("2026-08-06T12:00:00Z")
$rsa = [Security.Cryptography.RSA]::Create(3072)
$temp = Join-Path ([IO.Path]::GetTempPath()) ("external-owner-policy-" + [guid]::NewGuid().ToString("N"))
try {
    [void](New-Item -ItemType Directory -Path $temp)
    $pem = $rsa.ExportSubjectPublicKeyInfoPem()
    [byte[]]$spki = $rsa.ExportSubjectPublicKeyInfo()
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($spki)).ToLowerInvariant()
    $policy = [pscustomobject]@{ issuer_id="test-owner-authority-v1"; owner_login="Owner"; comment_marker="test-external-owner:v1"; max_authorization_age_seconds=86400; max_future_skew_seconds=300; maximum_comments=100; maximum_comment_bytes=65536; public_key_spki_sha256=$fingerprint; public_key_pem=$pem }
    $policyDocument = [ordered]@{schema="rusty.morphospace.workflow.external_owner_authorization_policy.v1";issuer_id=$policy.issuer_id;owner_login=$policy.owner_login;comment_marker=$policy.comment_marker;max_authorization_age_seconds=86400;max_future_skew_seconds=300;maximum_comments=100;maximum_response_bytes=1048576;maximum_comment_bytes=65536;public_key_spki_sha256=$fingerprint;public_key_pem=$pem.Replace("`r","")}
    $policySchemaPath = Join-Path $temp "policy.schema.json"
    $policySchema = Get-Content -Raw $policySchemaSource
    $policySchema = $policySchema.Replace('mesmerprism-owner-policy-authority-v1',$policy.issuer_id).Replace('MesmerPrism',$policy.owner_login).Replace('rusty-morphospace-external-owner-authorization:v1',$policy.comment_marker).Replace('e6ceb8c9bb2d3c178b28f15b9cd47ff1229e13584cd9c3b7dec1c2cda2f476e6',$fingerprint)
    [IO.File]::WriteAllText($policySchemaPath,$policySchema,[Text.UTF8Encoding]::new($false))
    $policyPath = Join-Path $temp "policy.json"
    [IO.File]::WriteAllText($policyPath,($policyDocument|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $null = Read-ExternalOwnerAuthorizationPolicy $policyPath $policySchemaPath
    $payload = [pscustomobject][ordered]@{
        schema="rusty.morphospace.workflow.external_owner_authorization_payload.v1"; issuer_id=$policy.issuer_id; authorization_id="authorization-00000001"; repository="Owner/repo"; pull_request_number=17
        base=[ordered]@{commit=("1"*40);tree=("2"*40)}; head=[ordered]@{commit=("3"*40);tree=("4"*40)}
        artifacts=@([ordered]@{path="scripts/gate.ps1";state="present";mode="100644";size_bytes=3;sha256=("a"*64)})
        assessment_sha256=("b"*64); request_sha256=("c"*64); issued_at="2026-08-06T11:59:00Z"; expires_at="2026-08-06T13:00:00Z"; decision="authorize-static-assessment"
        limitations=@("candidate_code_executed=false","execution_attested=false","acceptance_authority=false","publication_authority=false")
    }
    function New-Comment([object]$Value=$payload,[string]$Login="Owner") {
        [byte[]]$canonical = Get-CanonicalAuthorizationBytes $Value
        $sig = $rsa.SignData($canonical,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
        $doc=[ordered]@{schema="rusty.morphospace.workflow.external_owner_authorization.v1";payload=$Value;signature=[ordered]@{algorithm="RSA-PSS-SHA256";public_key_spki_sha256=$fingerprint;value_base64=[Convert]::ToBase64String($sig)}}
        return [pscustomobject]@{id=123;created_at="2026-08-06T11:59:30Z";updated_at="2026-08-06T11:59:30Z";user=[pscustomobject]@{login=$Login};body=([string]$policy.comment_marker+"`n"+($doc|ConvertTo-Json -Depth 30 -Compress))}
    }
    $positive = New-Comment
    $null = Test-ExternalOwnerAuthorizationComments @($positive) $payload $policy $now $schema
    $null = Test-ExternalOwnerAuthorizationComments @($positive) $payload $policy $now $schema
    $null = Test-ExternalOwnerAuthorizationComments @($positive,(New-Comment -Login "Other")) $payload $policy $now $schema
    $crlfComment = $positive | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -DateKind String
    $crlfComment.body = $crlfComment.body.Replace("`n", "`r`n")
    $null = Test-ExternalOwnerAuthorizationComments @($crlfComment) $payload $policy $now $schema
    $editedComment = $positive | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -DateKind String
    $editedComment.updated_at = "2026-08-06T11:59:31Z"
    $cases = @(
        @{name="missing pinned owner"; comments=@(New-Comment -Login "Other"); expected=$payload; at=$now; rejection="Exactly one pinned-owner authorization marker"},
        @{name="duplicate marker comments"; comments=@($positive,$positive); expected=$payload; at=$now; rejection="Exactly one pinned-owner authorization marker"},
        @{name="changed PR evidence"; comments=@($positive); expected=$payload; at=$now; rejection="Authorization payload does not equal the exact expected evidence"},
        @{name="edited owner comment"; comments=@($editedComment); expected=$payload; at=$now; rejection="Edited authorization comments are ambiguous and forbidden"},
        @{name="marker with leading whitespace"; comments=@([pscustomobject]@{id=124;created_at="2026-08-06T11:59:30Z";updated_at="2026-08-06T11:59:30Z";user=[pscustomobject]@{login="Owner"};body=(" " + $positive.body)}); expected=$payload; at=$now; rejection="Exactly one pinned-owner authorization marker"},
        @{name="duplicate marker in one body"; comments=@([pscustomobject]@{id=125;created_at="2026-08-06T11:59:30Z";updated_at="2026-08-06T11:59:30Z";user=[pscustomobject]@{login="Owner"};body=($positive.body + "`n" + $policy.comment_marker)}); expected=$payload; at=$now; rejection="Exactly one pinned-owner authorization marker"},
        @{name="marker on second line"; comments=@([pscustomobject]@{id=126;created_at="2026-08-06T11:59:30Z";updated_at="2026-08-06T11:59:30Z";user=[pscustomobject]@{login="Owner"};body=("discussion`n" + $positive.body)}); expected=$payload; at=$now; rejection="Authorization marker framing is not canonical"}
    )
    $wrong = $payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -DateKind String; $wrong.pull_request_number=18
    $cases[2].expected=$wrong
    $wrongArtifact = $payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -DateKind String; $wrongArtifact.artifacts[0].sha256=("c"*64)
    $wrongAssessment = $payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -DateKind String; $wrongAssessment.assessment_sha256=("d"*64)
    $stale = $payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -DateKind String; $stale.issued_at="2026-08-04T00:00:00Z"; $stale.expires_at="2026-08-04T01:00:00Z"
    $future = $payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 -DateKind String; $future.issued_at="2026-08-06T12:06:00Z"; $future.expires_at="2026-08-06T13:00:00Z"
    $badSignature=New-Comment; $badDoc=($badSignature.body -split "`n",2)[1]|ConvertFrom-Json -Depth 30 -DateKind String; $badDoc.signature.value_base64=([Convert]::ToBase64String([byte[]](1..200))); $badSignature.body=$policy.comment_marker+"`n"+($badDoc|ConvertTo-Json -Depth 30 -Compress)
    $wrongKeyPolicy=$policy.PSObject.Copy(); $wrongKeyPolicy.public_key_spki_sha256=("0"*64)
    $more=@(
      @{name="stale";comments=@(New-Comment $stale);expected=$stale;at=$now;policy=$policy;rejection="Authorization is stale"},
      @{name="future";comments=@(New-Comment $future);expected=$future;at=$now;policy=$policy;rejection="Authorization was issued too far in the future"},
      @{name="wrong artifact";comments=@($positive);expected=$wrongArtifact;at=$now;policy=$policy;rejection="Authorization payload does not equal the exact expected evidence"},
      @{name="wrong assessment";comments=@($positive);expected=$wrongAssessment;at=$now;policy=$policy;rejection="Authorization payload does not equal the exact expected evidence"},
      @{name="wrong signature";comments=@($badSignature);expected=$payload;at=$now;policy=$policy;rejection="Authorization signature verification failed"},
      @{name="wrong key";comments=@($positive);expected=$payload;at=$now;policy=$wrongKeyPolicy;rejection="Authorization key fingerprint is not pinned"}
    )
    $cases += $more
    foreach ($case in $cases) {
        $casePolicy = if ($case.ContainsKey("policy")) { $case.policy } else { $policy }
        $failure = ""
        try {
            $null = Test-ExternalOwnerAuthorizationComments $case.comments $case.expected $casePolicy $case.at $schema
        } catch {
            $failure = $_.Exception.Message
        }
        if ([string]::IsNullOrEmpty($failure)) {
            throw "Negative case passed: $($case.name)"
        }
        if ($failure -notmatch [string]$case.rejection) {
            throw "Negative case '$($case.name)' failed for the wrong reason: $failure"
        }
    }
    $validPolicyText = $policyDocument|ConvertTo-Json -Depth 10
    $duplicatePolicy = $validPolicyText -replace '("issuer_id"\s*:\s*"test-owner-authority-v1")',('$1,'+"`n"+'  "issuer_id": "test-owner-authority-v1"')
    $alteredPolicy = $validPolicyText|ConvertFrom-Json -Depth 10;$alteredPolicy.issuer_id="altered-owner-authority-v1"
    $malformedPolicy = $validPolicyText|ConvertFrom-Json -Depth 10;$malformedPolicy.public_key_pem="-----BEGIN PUBLIC KEY-----`n"+("A"*600)+"`n-----END PUBLIC KEY-----"
    $policyNegatives = @(
        @{name="duplicate key";text=$duplicatePolicy},
        @{name="altered pinned constant";text=($alteredPolicy|ConvertTo-Json -Depth 10)},
        @{name="malformed PEM/fingerprint";text=($malformedPolicy|ConvertTo-Json -Depth 10)},
        @{name="oversized policy";text=(" "*17000)+($policyDocument|ConvertTo-Json -Depth 10)}
    )
    foreach($case in $policyNegatives){[IO.File]::WriteAllText($policyPath,[string]$case.text,[Text.UTF8Encoding]::new($false));$failed=$false;try{$null=Read-ExternalOwnerAuthorizationPolicy $policyPath $policySchemaPath}catch{$failed=$true};if(-not $failed){throw "Negative policy case passed: $($case.name)"}}
    $signingHelper = Get-Content -Raw (Join-Path $PSScriptRoot "New-ExternalOwnerAuthorizationComment.ps1")
    $bytePreflightIndex = $signingHelper.IndexOf('Test-CanonicalTextBytes.ps1',[StringComparison]::Ordinal)
    $policyReadIndex = $signingHelper.IndexOf('Read-ExternalOwnerAuthorizationPolicy',[StringComparison]::Ordinal)
    $keyOpenIndex = $signingHelper.IndexOf('ImportFromPem',[StringComparison]::Ordinal)
    if ($bytePreflightIndex -lt 0 -or $policyReadIndex -lt 0 -or $keyOpenIndex -lt 0 -or $bytePreflightIndex -gt $policyReadIndex -or $bytePreflightIndex -gt $keyOpenIndex) {
        throw "External owner signing helper must run canonical text-byte preflight before policy or key use."
    }
    if (
        $signingHelper -match '\[IO\.File\]::WriteAllBytes' -or
        $signingHelper -notmatch '\[IO\.FileStream\]::new' -or
        $signingHelper -notmatch '\[IO\.FileMode\]::CreateNew' -or
        $signingHelper -notmatch '\.Flush\(\$true\)'
    ) {
        throw "External owner signing helper must publish comment files with an exclusive durable CreateNew FileStream."
    }
    $crlfRequestPath = Join-Path $temp "noncanonical-crlf-request.json"
    [IO.File]::WriteAllBytes($crlfRequestPath, [Text.UTF8Encoding]::new($false).GetBytes("{`r`n}`r`n"))
    $crlfFailure = ""
    try {
        & (Join-Path $PSScriptRoot "New-ExternalOwnerAuthorizationComment.ps1") `
            -RequestPath $crlfRequestPath `
            -AuthorizationId "noncanonical-request-probe" `
            -IssuedAt "2026-08-06T11:59:00Z" `
            -ExpiresAt "2026-08-06T13:00:00Z" `
            -CertificateThumbprint ("0" * 40) | Out-Null
    } catch {
        $crlfFailure = $_.Exception.Message
    }
    if ($crlfFailure -notmatch 'eol002-evidence-crlf') {
        throw "CRLF authorization request was not rejected before signing-key access: $crlfFailure"
    }
    $helperRoot = Join-Path $temp "helper-root"
    foreach ($directory in @("scripts", "scripts/lib", "schemas", "config")) {
        [void](New-Item -ItemType Directory -Path (Join-Path $helperRoot $directory) -Force)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "New-ExternalOwnerAuthorizationComment.ps1") -Destination (Join-Path $helperRoot "scripts/New-ExternalOwnerAuthorizationComment.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "Test-CanonicalTextBytes.ps1") -Destination (Join-Path $helperRoot "scripts/Test-CanonicalTextBytes.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "lib/ExternalOwnerAuthorization.psm1") -Destination (Join-Path $helperRoot "scripts/lib/ExternalOwnerAuthorization.psm1")
    foreach ($schemaName in @("external-owner-authorization-request-v1.schema.json", "external-validation-authority-assessment-v1.schema.json", "external-owner-authorization-v1.schema.json")) {
        Copy-Item -LiteralPath (Join-Path $root "schemas/$schemaName") -Destination (Join-Path $helperRoot "schemas/$schemaName")
    }
    [IO.File]::WriteAllText((Join-Path $helperRoot "schemas/external-owner-authorization-policy-v1.schema.json"),$policySchema,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $helperRoot "config/external-owner-authorization.json"),($policyDocument|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $privateKeyPath = Join-Path $temp "owner-private-key.pem"
    [IO.File]::WriteAllText($privateKeyPath,$rsa.ExportPkcs8PrivateKeyPem(),[Text.UTF8Encoding]::new($false))
    $requestAssessment = [ordered]@{
        schema="rusty.morphospace.workflow.external_validation_authority_assessment.v1";policy_id="test-validation-authority-v1";policy_sha256=("d"*64);repository="Owner/repo"
        base=[ordered]@{commit=("1"*40);tree=("2"*40)};candidate=[ordered]@{commit=("3"*40);tree=("4"*40)}
        changed_paths=@("scripts/gate.ps1");protected_paths=@("scripts/gate.ps1");decision="external-owner-authorization";approval_id="external-owner-authorization-required"
        candidate_code_executed=$false;execution_attested=$false;publication_authority=$false
        limitations=@("Static admission only; no candidate code was executed.","Execution, tests, acceptance, and publication remain separately authorized.","External owner authorization permits only this base verifier assessment.")
    }
    $request = New-ExternalOwnerAuthorizationRequest $policy.issuer_id "Owner/repo" 17 $requestAssessment.base $requestAssessment.candidate @([ordered]@{path="scripts/gate.ps1";state="present";mode="100644";size_bytes=3;sha256=("a"*64)}) $requestAssessment
    foreach ($invalidTimestamp in @(
        "2026-08-06T11:59:00+00:00",
        "2026-08-06T11:59:00.000Z",
        "2026-08-06T11:59:00Z ",
        "2026-08-06 11:59:00Z",
        "2026-02-30T11:59:00Z"
    )) {
        $failed = $false
        try {
            $null = New-ExternalOwnerAuthorizationPayload $request "authorization-00000001" $invalidTimestamp "2026-08-06T13:00:00Z"
        } catch {
            $failed = $_.Exception.Message -match "canonical UTC-second timestamp"
        }
        if (-not $failed) { throw "Noncanonical authorization timestamp was accepted: $invalidTimestamp" }
    }
    $requestPath = Join-Path $temp "authorization-request.json"
    $helperRequestText = ($request | ConvertTo-Json -Depth 30).Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($requestPath, ($helperRequestText + "`n"), [Text.UTF8Encoding]::new($false))
    $helperPath = Join-Path $helperRoot "scripts/New-ExternalOwnerAuthorizationComment.ps1"
    $missingPrivateKeyPath = Join-Path $temp "missing-private-key.pem"
    foreach ($timestampCase in @(
        @{ name = "IssuedAt"; issued = "2026-08-06T11:59:00+00:00"; expires = "2026-08-06T13:00:00Z" },
        @{ name = "ExpiresAt"; issued = "2026-08-06T11:59:00Z"; expires = "2026-08-06T13:00:00.000Z" }
    )) {
        $timestampOutput = [Collections.Generic.List[object]]::new()
        $timestampFailure = ""
        try {
            & $helperPath `
                -RequestPath $requestPath `
                -AuthorizationId "full-authority-pr157-54753ee7-20260910t094152z" `
                -IssuedAt ([string]$timestampCase.issued) `
                -ExpiresAt ([string]$timestampCase.expires) `
                -PrivateKeyPemPath $missingPrivateKeyPath |
                ForEach-Object { $timestampOutput.Add($_) }
        } catch {
            $timestampFailure = $_.Exception.Message
        }
        if ($timestampOutput.Count -ne 0 -or $timestampFailure -notmatch "canonical UTC-second timestamp") {
            throw "Signing helper did not reject invalid $($timestampCase.name) before key access: output=$($timestampOutput.Count) failure=$timestampFailure"
        }
    }
    $invalidOutput = [Collections.Generic.List[object]]::new()
    $invalidIdFailure = ""
    try {
        & $helperPath -RequestPath $requestPath -AuthorizationId "full-authority-pr157-54753ee7-20260910T094152Z" -IssuedAt "2026-08-06T11:59:00Z" -ExpiresAt "2026-08-06T13:00:00Z" -PrivateKeyPemPath $privateKeyPath |
            ForEach-Object { $invalidOutput.Add($_) }
    } catch {
        $invalidIdFailure = $_.Exception.Message
    }
    if ($invalidOutput.Count -ne 0 -or $invalidIdFailure -notmatch "'/payload/authorization_id'") {
        throw "Signing helper did not reject the invalid authorization ID before output: output=$($invalidOutput.Count) failure=$invalidIdFailure"
    }
    $validAuthorizationId = "full-authority-pr157-54753ee7-20260910t094152z"
    $commentOutputPath = Join-Path $temp "authorization-comment.txt"
    $validOutput = @(
        & $helperPath `
            -RequestPath $requestPath `
            -AuthorizationId $validAuthorizationId `
            -IssuedAt "2026-08-06T11:59:00Z" `
            -ExpiresAt "2026-08-06T13:00:00Z" `
            -PrivateKeyPemPath $privateKeyPath `
            -OutputPath $commentOutputPath
    )
    if ($validOutput.Count -ne 2 -or $validOutput[0] -cne [string]$policy.comment_marker) {
        throw "Signing helper did not emit the canonical two-line authorization comment."
    }
    [byte[]]$commentBytes = [IO.File]::ReadAllBytes($commentOutputPath)
    if (
        $commentBytes.Length -lt 2 -or
        $commentBytes -contains 0x0D -or
        ($commentBytes.Length -ge 3 -and $commentBytes[0] -eq 0xEF -and $commentBytes[1] -eq 0xBB -and $commentBytes[2] -eq 0xBF) -or
        $commentBytes[$commentBytes.Length - 1] -ne 0x0A
    ) {
        throw "Signing helper did not persist UTF-8-no-BOM LF-only comment bytes."
    }
    $persistedComment = [Text.UTF8Encoding]::new($false, $true).GetString($commentBytes)
    if ($persistedComment -cne (([string]$validOutput[0]) + "`n" + ([string]$validOutput[1]) + "`n")) {
        throw "Signing helper persisted comment bytes differ from emitted comment text."
    }
    $sentinelOutputPath = Join-Path $temp "authorization-comment-sentinel.txt"
    [byte[]]$sentinelBytes = [byte[]](0x73, 0x65, 0x6E, 0x74, 0x69, 0x6E, 0x65, 0x6C)
    [IO.File]::WriteAllBytes($sentinelOutputPath, $sentinelBytes)
    $sentinelFailure = ""
    try {
        & $helperPath `
            -RequestPath $requestPath `
            -AuthorizationId $validAuthorizationId `
            -IssuedAt "2026-08-06T11:59:00Z" `
            -ExpiresAt "2026-08-06T13:00:00Z" `
            -PrivateKeyPemPath $privateKeyPath `
            -OutputPath $sentinelOutputPath | Out-Null
    } catch {
        $sentinelFailure = $_.Exception.Message
    }
    if ($sentinelFailure -notmatch "already exists|CreateNew") {
        throw "Signing helper did not reject an existing output path: $sentinelFailure"
    }
    if (([Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinelOutputPath))) -cne [Convert]::ToBase64String($sentinelBytes)) {
        throw "Signing helper overwrote a pre-existing authorization comment file."
    }
    $validDocument = ConvertFrom-ExternalOwnerJsonStrict -Json ([string]$validOutput[1])
    $expectedHelperPayload = New-ExternalOwnerAuthorizationPayload `
        $request `
        $validAuthorizationId `
        "2026-08-06T11:59:00Z" `
        "2026-08-06T13:00:00Z"
    $helperComment = [pscustomobject]@{
        id = 456
        created_at = "2026-08-06T11:59:30Z"
        updated_at = "2026-08-06T11:59:30Z"
        user = [pscustomobject]@{ login = "Owner" }
        body = $persistedComment.TrimEnd("`n")
    }
    $null = Test-ExternalOwnerAuthorizationComments @($helperComment) $expectedHelperPayload $policy $now $schema
    if ([string]$validDocument.payload.authorization_id -cne $validAuthorizationId) {
        throw "Signing helper changed the valid authorization ID."
    }
    Write-Output "External owner authorization tests passed (canonical timestamps, LF/CRLF framing, edited-comment rejection, validated LF-only output persistence, exact evidence, byte-preflight ordering, and identity, time, signature, and key negatives)."
} finally { $rsa.Dispose(); if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }
