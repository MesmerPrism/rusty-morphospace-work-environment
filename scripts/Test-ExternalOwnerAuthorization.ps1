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
    $cases = @(
        @{name="missing pinned owner"; comments=@(New-Comment -Login "Other"); expected=$payload; at=$now},
        @{name="duplicate marker comments"; comments=@($positive,$positive); expected=$payload; at=$now},
        @{name="changed PR evidence"; comments=@($positive); expected=$payload; at=$now}
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
      @{name="stale";comments=@(New-Comment $stale);expected=$stale;at=$now;policy=$policy},
      @{name="future";comments=@(New-Comment $future);expected=$future;at=$now;policy=$policy},
      @{name="wrong artifact";comments=@($positive);expected=$wrongArtifact;at=$now;policy=$policy},
      @{name="wrong assessment";comments=@($positive);expected=$wrongAssessment;at=$now;policy=$policy},
      @{name="wrong signature";comments=@($badSignature);expected=$payload;at=$now;policy=$policy},
      @{name="wrong key";comments=@($positive);expected=$payload;at=$now;policy=$wrongKeyPolicy}
    )
    $cases += $more
    foreach($case in $cases){ $failed=$false; try{$p=if($case.policy){$case.policy}else{$policy};$null=Test-ExternalOwnerAuthorizationComments $case.comments $case.expected $p $case.at $schema}catch{$failed=$true};if(-not $failed){throw "Negative case passed: $($case.name)"} }
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
    Write-Output "External owner authorization tests passed (exact-evidence idempotence, executed byte-preflight ordering, and changed evidence, policy, identity, time, signature, and key negatives)."
} finally { $rsa.Dispose(); if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }
