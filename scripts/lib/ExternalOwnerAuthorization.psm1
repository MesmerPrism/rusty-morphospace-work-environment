Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Initialize-ExternalOwnerAuthorizationTypes {
    if ("RustyMorphospace.ExternalOwnerCrypto" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RustyMorphospace {
  public static class ExternalOwnerCrypto {
    static void WriteCanonical(Utf8JsonWriter w, JsonElement e) {
      switch (e.ValueKind) {
        case JsonValueKind.Object:
          w.WriteStartObject();
          var properties = new List<JsonProperty>();
          foreach (var p in e.EnumerateObject()) properties.Add(p);
          properties.Sort((a,b) => StringComparer.Ordinal.Compare(a.Name,b.Name));
          string prior = null;
          foreach (var p in properties) {
            if (prior != null && StringComparer.OrdinalIgnoreCase.Equals(prior,p.Name))
              throw new InvalidDataException("Duplicate or case-colliding JSON property.");
            prior = p.Name; w.WritePropertyName(p.Name); WriteCanonical(w,p.Value);
          }
          w.WriteEndObject(); break;
        case JsonValueKind.Array:
          w.WriteStartArray(); foreach (var v in e.EnumerateArray()) WriteCanonical(w,v); w.WriteEndArray(); break;
        case JsonValueKind.String: w.WriteStringValue(e.GetString()); break;
        case JsonValueKind.Number:
          if (e.TryGetInt64(out long n)) w.WriteNumberValue(n); else throw new InvalidDataException("Non-integer JSON number.");
          break;
        case JsonValueKind.True: w.WriteBooleanValue(true); break;
        case JsonValueKind.False: w.WriteBooleanValue(false); break;
        case JsonValueKind.Null: w.WriteNullValue(); break;
        default: throw new InvalidDataException("Unsupported JSON token.");
      }
    }
    public static byte[] Canonicalize(string json) {
      var options = new JsonDocumentOptions { AllowTrailingCommas=false, CommentHandling=JsonCommentHandling.Disallow, MaxDepth=32 };
      using (var doc = JsonDocument.Parse(json, options))
      using (var stream = new MemoryStream()) {
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented=false })) WriteCanonical(writer,doc.RootElement);
        return stream.ToArray();
      }
    }
    public static string SpkiSha256(string pem) {
      using (RSA rsa = RSA.Create()) { rsa.ImportFromPem(pem); return Convert.ToHexString(SHA256.HashData(rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant(); }
    }
    public static bool Verify(string pem, byte[] data, byte[] signature) {
      using (RSA rsa = RSA.Create()) { rsa.ImportFromPem(pem); return rsa.VerifyData(data,signature,HashAlgorithmName.SHA256,RSASignaturePadding.Pss); }
    }
  }
}
'@
}

function Get-CanonicalAuthorizationBytes {
    param([Parameter(Mandatory)][object]$Payload)
    Initialize-ExternalOwnerAuthorizationTypes
    $json = $Payload | ConvertTo-Json -Depth 30 -Compress
    return ,[RustyMorphospace.ExternalOwnerCrypto]::Canonicalize($json)
}

function ConvertFrom-ExternalOwnerJsonStrict {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    Initialize-ExternalOwnerAuthorizationTypes
    $null = [RustyMorphospace.ExternalOwnerCrypto]::Canonicalize($Json)
    if ($Json.Trim() -ceq "[]") { return }
    $value = $Json | ConvertFrom-Json -Depth 30 -DateKind String
    return $value
}

function Read-ExternalOwnerAuthorizationPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [ValidateRange(1,1048576)][int]$MaximumBytes = 16384
    )
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    [byte[]]$raw = [IO.File]::ReadAllBytes($resolved)
    if ($raw.Length -gt $MaximumBytes) { throw "External owner authorization policy exceeds its size bound." }
    try {
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($raw)
    } catch {
        throw "External owner authorization policy is not valid UTF-8."
    }
    $policy = ConvertFrom-ExternalOwnerJsonStrict -Json $text
    [byte[]]$canonical = Get-CanonicalAuthorizationBytes -Payload $policy
    $canonicalJson = [Text.Encoding]::UTF8.GetString($canonical)
    if (-not (Test-Json -Json $canonicalJson -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw "External owner authorization policy failed its schema."
    }
    try {
        $actualFingerprint = [RustyMorphospace.ExternalOwnerCrypto]::SpkiSha256([string]$policy.public_key_pem)
    } catch {
        throw "External owner authorization policy public key is malformed."
    }
    if ($actualFingerprint -cne [string]$policy.public_key_spki_sha256) {
        throw "External owner authorization policy public key fingerprint is inconsistent."
    }
    return $policy
}

function Get-ExternalOwnerSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function New-ExternalOwnerAuthorizationRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IssuerId,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$PullRequestNumber,
        [Parameter(Mandatory)][object]$Base,
        [Parameter(Mandatory)][object]$Head,
        [Parameter(Mandatory)][object[]]$Artifacts,
        [Parameter(Mandatory)][object]$Assessment
    )
    $paths = @($Artifacts | ForEach-Object { [string]$_.path })
    $sorted = @($paths | Sort-Object -CaseSensitive)
    if (($paths -join "`n") -cne ($sorted -join "`n") -or @($paths | Sort-Object -Unique -CaseSensitive).Count -ne $paths.Count) {
        throw "Authorization artifacts must be complete, unique, and ordinal sorted."
    }
    $stableAssessment = $Assessment | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json -Depth 30 -DateKind String
    [byte[]]$assessmentBytes = Get-CanonicalAuthorizationBytes -Payload $stableAssessment
    return [ordered]@{
        schema = "rusty.morphospace.workflow.external_owner_authorization_request.v1"
        issuer_id = $IssuerId
        repository = $Repository
        pull_request_number = $PullRequestNumber
        base = $Base
        head = $Head
        artifacts = $Artifacts
        assessment = $stableAssessment
        assessment_sha256 = Get-ExternalOwnerSha256 $assessmentBytes
        limitations = @("candidate_code_executed=false","execution_attested=false","acceptance_authority=false","publication_authority=false")
    }
}

function New-ExternalOwnerAuthorizationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$IssuedAt,
        [Parameter(Mandatory)][string]$ExpiresAt
    )
    [byte[]]$assessmentBytes = Get-CanonicalAuthorizationBytes -Payload ($Request.assessment)
    if ((Get-ExternalOwnerSha256 $assessmentBytes) -cne [string]$Request.assessment_sha256) { throw "Authorization request assessment hash is inconsistent." }
    [byte[]]$requestBytes = Get-CanonicalAuthorizationBytes $Request
    return [ordered]@{
        schema = "rusty.morphospace.workflow.external_owner_authorization_payload.v1"
        issuer_id = [string]$Request.issuer_id
        authorization_id = $AuthorizationId
        repository = [string]$Request.repository
        pull_request_number = [int]$Request.pull_request_number
        base = $Request.base
        head = $Request.head
        artifacts = @($Request.artifacts)
        assessment_sha256 = [string]$Request.assessment_sha256
        request_sha256 = Get-ExternalOwnerSha256 $requestBytes
        issued_at = $IssuedAt
        expires_at = $ExpiresAt
        decision = "authorize-static-assessment"
        limitations = @($Request.limitations)
    }
}

function Test-ExternalOwnerAuthorizationComments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Comments,
        [Parameter(Mandatory)][object]$ExpectedPayload,
        [Parameter(Mandatory)][object]$Policy,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
        [Parameter(Mandatory)][string]$SchemaPath
    )
    Initialize-ExternalOwnerAuthorizationTypes
    if ($Comments.Count -gt [int]$Policy.maximum_comments) { throw "Comment count exceeds the configured bound." }
    $markerPattern = "(?m)^$([regex]::Escape([string]$Policy.comment_marker))$"
    $ownerMarkerCount = 0
    $matchedComments = [Collections.Generic.List[object]]::new()
    foreach ($candidateComment in $Comments) {
        if ([string]$candidateComment.user.login -cne [string]$Policy.owner_login) { continue }
        if ($null -eq $candidateComment.id -or $null -eq $candidateComment.created_at -or $null -eq $candidateComment.updated_at) { throw "Comment identity and timestamps are required." }
        if ([string]$candidateComment.created_at -cne [string]$candidateComment.updated_at) { throw "Edited authorization comments are ambiguous and forbidden." }
        $count = [regex]::Matches([string]$candidateComment.body,$markerPattern).Count
        $ownerMarkerCount += $count
        if ($count -gt 0) { $matchedComments.Add($candidateComment) }
    }
    $matches = @($matchedComments)
    if ($matches.Count -ne 1 -or $ownerMarkerCount -ne 1) { throw "Exactly one pinned-owner authorization marker is required in exactly one comment." }
    $comment = $matches[0]
    [string]$body = $comment.body
    if ([Text.Encoding]::UTF8.GetByteCount($body) -gt [int]$Policy.maximum_comment_bytes) { throw "Authorization comment exceeds the size bound." }
    $lines = $body -split "\r?\n", 2
    if ($lines.Count -ne 2 -or $lines[0] -cne [string]$Policy.comment_marker) { throw "Authorization marker framing is not canonical." }
    [byte[]]$rawCanonical = [RustyMorphospace.ExternalOwnerCrypto]::Canonicalize($lines[1])
    $document = $lines[1] | ConvertFrom-Json -Depth 30 -DateKind String
    $documentJson = $document | ConvertTo-Json -Depth 30 -Compress
    [byte[]]$roundTripCanonical = [RustyMorphospace.ExternalOwnerCrypto]::Canonicalize($documentJson)
    if ([Convert]::ToBase64String($rawCanonical) -cne [Convert]::ToBase64String($roundTripCanonical)) { throw "Authorization JSON is not losslessly representable." }
    if (-not (Test-Json -Json $documentJson -SchemaFile $SchemaPath -ErrorAction Stop)) { throw "Authorization document failed its schema." }
    if ([string]$document.payload.issuer_id -cne [string]$Policy.issuer_id) { throw "Authorization issuer is not pinned." }
    if ([string]$document.signature.algorithm -cne "RSA-PSS-SHA256") { throw "Authorization signature algorithm is not supported." }
    if ([string]$document.signature.public_key_spki_sha256 -cne [string]$Policy.public_key_spki_sha256) { throw "Authorization key fingerprint is not pinned." }
    if ([RustyMorphospace.ExternalOwnerCrypto]::SpkiSha256([string]$Policy.public_key_pem) -cne [string]$Policy.public_key_spki_sha256) { throw "Configured public key fingerprint is inconsistent." }
    $actualCanonical = Get-CanonicalAuthorizationBytes $document.payload
    $expectedCanonical = Get-CanonicalAuthorizationBytes $ExpectedPayload
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($actualCanonical,$expectedCanonical)) { throw "Authorization payload does not equal the exact expected evidence." }
    $issued = [datetimeoffset]::ParseExact([string]$document.payload.issued_at,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
    $expires = [datetimeoffset]::ParseExact([string]$document.payload.expires_at,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
    if ($issued -gt $Now.AddSeconds([int]$Policy.max_future_skew_seconds)) { throw "Authorization was issued too far in the future." }
    if ($issued -lt $Now.AddSeconds(-[int]$Policy.max_authorization_age_seconds)) { throw "Authorization is stale." }
    if ($expires -le $Now -or $expires -le $issued -or $expires -gt $issued.AddSeconds([int]$Policy.max_authorization_age_seconds)) { throw "Authorization expiry is invalid." }
    try { [byte[]]$signature = [Convert]::FromBase64String([string]$document.signature.value_base64) } catch { throw "Authorization signature is not canonical base64." }
    if ([Convert]::ToBase64String($signature) -cne [string]$document.signature.value_base64) { throw "Authorization signature is not canonical base64." }
    if (-not [RustyMorphospace.ExternalOwnerCrypto]::Verify([string]$Policy.public_key_pem,$actualCanonical,$signature)) { throw "Authorization signature verification failed." }
    return $document.payload
}

function Test-ExternalOwnerSignedPayload {
    <#
    .SYNOPSIS
    Verifies one non-comment external-owner signed payload against exact,
    caller-supplied evidence.  This deliberately reuses the pinned policy and
    canonical RSA-PSS implementation but does not grant comment/PR authority.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DocumentText,
        [Parameter(Mandatory)][object]$ExpectedPayload,
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$SchemaPath,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    Initialize-ExternalOwnerAuthorizationTypes
    [byte[]]$rawCanonical = [RustyMorphospace.ExternalOwnerCrypto]::Canonicalize($DocumentText)
    $document = ConvertFrom-ExternalOwnerJsonStrict -Json $DocumentText
    $roundTripText = $document | ConvertTo-Json -Depth 32 -Compress
    [byte[]]$roundTripCanonical = [RustyMorphospace.ExternalOwnerCrypto]::Canonicalize($roundTripText)
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($rawCanonical, $roundTripCanonical)) {
        throw 'Signed authorization JSON is not losslessly representable.'
    }
    if (-not (Test-Json -Json ([Text.Encoding]::UTF8.GetString($roundTripCanonical)) -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw 'Signed authorization document failed its schema.'
    }
    if ([string]$document.payload.issuer_id -cne [string]$Policy.issuer_id) {
        throw 'Signed authorization issuer is not pinned.'
    }
    if ([string]$document.signature.algorithm -cne 'RSA-PSS-SHA256') {
        throw 'Signed authorization algorithm is not supported.'
    }
    if ([string]$document.signature.public_key_spki_sha256 -cne [string]$Policy.public_key_spki_sha256) {
        throw 'Signed authorization key fingerprint is not pinned.'
    }
    if ([RustyMorphospace.ExternalOwnerCrypto]::SpkiSha256([string]$Policy.public_key_pem) -cne [string]$Policy.public_key_spki_sha256) {
        throw 'Configured external-owner public key fingerprint is inconsistent.'
    }
    [byte[]]$actualCanonical = Get-CanonicalAuthorizationBytes -Payload $document.payload
    [byte[]]$expectedCanonical = Get-CanonicalAuthorizationBytes -Payload $ExpectedPayload
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($actualCanonical, $expectedCanonical)) {
        throw 'Signed authorization payload does not equal the exact expected evidence.'
    }
    $issued = [datetimeoffset]::ParseExact([string]$document.payload.issued_at, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    $expires = [datetimeoffset]::ParseExact([string]$document.payload.expires_at, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    if ($issued -gt $Now.AddSeconds([int]$Policy.max_future_skew_seconds)) {
        throw 'Signed authorization was issued too far in the future.'
    }
    if ($issued -lt $Now.AddSeconds(-[int]$Policy.max_authorization_age_seconds)) {
        throw 'Signed authorization is stale.'
    }
    if ($expires -le $Now -or $expires -le $issued -or $expires -gt $issued.AddSeconds([int]$Policy.max_authorization_age_seconds)) {
        throw 'Signed authorization expiry is invalid.'
    }
    try { [byte[]]$signature = [Convert]::FromBase64String([string]$document.signature.value_base64) }
    catch { throw 'Signed authorization signature is not canonical base64.' }
    if ([Convert]::ToBase64String($signature) -cne [string]$document.signature.value_base64) {
        throw 'Signed authorization signature is not canonical base64.'
    }
    if (-not [RustyMorphospace.ExternalOwnerCrypto]::Verify([string]$Policy.public_key_pem, $actualCanonical, $signature)) {
        throw 'Signed authorization signature verification failed.'
    }
    return $document.payload
}

Export-ModuleMember -Function Get-CanonicalAuthorizationBytes, ConvertFrom-ExternalOwnerJsonStrict, Read-ExternalOwnerAuthorizationPolicy, Get-ExternalOwnerSha256, New-ExternalOwnerAuthorizationRequest, New-ExternalOwnerAuthorizationPayload, Test-ExternalOwnerAuthorizationComments, Test-ExternalOwnerSignedPayload
