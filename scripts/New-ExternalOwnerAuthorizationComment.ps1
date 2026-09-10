param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$AuthorizationId,
    [Parameter(Mandatory)][string]$IssuedAt,
    [Parameter(Mandatory)][string]$ExpiresAt,
    [string]$PrivateKeyPemPath = "",
    [string]$CertificateThumbprint = "",
    [string]$OutputPath = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (($PrivateKeyPemPath -eq "") -eq ($CertificateThumbprint -eq "")) { throw "Specify exactly one external signing source." }
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot "lib/ExternalOwnerAuthorization.psm1") -Force
$bytePreflight = & (Join-Path $PSScriptRoot "Test-CanonicalTextBytes.ps1") `
    -EvidencePath (Resolve-Path -LiteralPath $RequestPath -ErrorAction Stop).Path `
    -Json `
    -NoThrow |
    ConvertFrom-Json -Depth 12
if ($bytePreflight.advisory_status -cne "pass") {
    throw "External owner authorization request byte preflight failed: $($bytePreflight.reason_codes -join ', ')."
}
$policy = Read-ExternalOwnerAuthorizationPolicy `
    -Path (Join-Path $root "config/external-owner-authorization.json") `
    -SchemaPath (Join-Path $root "schemas/external-owner-authorization-policy-v1.schema.json")
$requestText = Get-Content -Raw $RequestPath
$request = ConvertFrom-ExternalOwnerJsonStrict $requestText
$requestCanonical = Get-CanonicalAuthorizationBytes $request
if (-not (Test-Json -Json ([Text.Encoding]::UTF8.GetString($requestCanonical)) -SchemaFile (Join-Path $root "schemas/external-owner-authorization-request-v1.schema.json") -ErrorAction Stop)) { throw "Authorization request failed its schema." }
if (-not (Test-Json -Json ($request.assessment|ConvertTo-Json -Depth 30) -SchemaFile (Join-Path $root "schemas/external-validation-authority-assessment-v1.schema.json") -ErrorAction Stop)) { throw "Authorization request assessment failed its schema." }
$payload = New-ExternalOwnerAuthorizationPayload $request $AuthorizationId $IssuedAt $ExpiresAt
[byte[]]$bytes = Get-CanonicalAuthorizationBytes $payload
$rsa = $null
try {
    if ($PrivateKeyPemPath) {
        $rsa = [Security.Cryptography.RSA]::Create()
        $rsa.ImportFromPem((Get-Content -Raw $PrivateKeyPemPath))
    } else {
        if ($CertificateThumbprint -cnotmatch "^[0-9A-Fa-f]{40}$") { throw "Certificate thumbprint is malformed." }
        $store = [Security.Cryptography.X509Certificates.X509Store]::new("My","CurrentUser")
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        try { $certs = @($store.Certificates | Where-Object Thumbprint -eq $CertificateThumbprint) } finally { $store.Dispose() }
        if ($certs.Count -ne 1 -or -not $certs[0].HasPrivateKey) { throw "Exactly one signing certificate with a private key is required." }
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certs[0])
    }
    $actualFingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    if($actualFingerprint -cne [string]$policy.public_key_spki_sha256){throw "External signing key does not equal the pinned public key."}
    [byte[]]$signature = $rsa.SignData($bytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
} finally { if ($null -ne $rsa) { $rsa.Dispose() } }
$document = [ordered]@{
    schema = "rusty.morphospace.workflow.external_owner_authorization.v1"
    payload = $payload
    signature = [ordered]@{ algorithm="RSA-PSS-SHA256"; public_key_spki_sha256=[string]$policy.public_key_spki_sha256; value_base64=[Convert]::ToBase64String($signature) }
}
$documentText = $document | ConvertTo-Json -Depth 30 -Compress
if (-not (Test-Json -Json $documentText -SchemaFile (Join-Path $root "schemas/external-owner-authorization-v1.schema.json") -ErrorAction Stop)) {
    throw "Generated external owner authorization failed its schema."
}
$commentText = [string]$policy.comment_marker + "`n" + $documentText + "`n"
if ($OutputPath) {
    $outputFullPath = [IO.Path]::GetFullPath($OutputPath)
    $outputParent = Split-Path -Parent $outputFullPath
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        throw "Authorization comment output directory does not exist."
    }
    [byte[]]$commentBytes = [Text.UTF8Encoding]::new($false).GetBytes($commentText)
    $outputStream = [IO.FileStream]::new(
        $outputFullPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $outputStream.Write($commentBytes, 0, $commentBytes.Length)
        $outputStream.Flush($true)
    } finally {
        $outputStream.Dispose()
    }
    [byte[]]$persistedBytes = [IO.File]::ReadAllBytes($outputFullPath)
    if (
        $persistedBytes.Length -lt 2 -or
        $persistedBytes -contains 0x0D -or
        ($persistedBytes.Length -ge 3 -and $persistedBytes[0] -eq 0xEF -and $persistedBytes[1] -eq 0xBB -and $persistedBytes[2] -eq 0xBF) -or
        $persistedBytes[$persistedBytes.Length - 1] -ne 0x0A
    ) {
        throw "Authorization comment output is not UTF-8-no-BOM LF-only text."
    }
    try {
        $persistedText = [Text.UTF8Encoding]::new($false, $true).GetString($persistedBytes)
    } catch {
        throw "Authorization comment output is not valid UTF-8."
    }
    if ($persistedText -cne $commentText) {
        throw "Authorization comment output did not persist byte-exactly."
    }
    $frame = Get-ExternalOwnerAuthorizationCommentFrame -Body $persistedText -Marker ([string]$policy.comment_marker)
    if ($frame.marker_count -ne 1 -or $null -eq $frame.document_text) {
        throw "Authorization comment output framing is not canonical."
    }
    $issued = [datetimeoffset]::ParseExact(
        (ConvertTo-ExternalOwnerCanonicalUtcSecond -Value ([string]$payload.issued_at) -Label "Authorization issued_at"),
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
    $null = Test-ExternalOwnerSignedPayload -DocumentText $frame.document_text -ExpectedPayload $payload -Policy $policy -SchemaPath (Join-Path $root "schemas/external-owner-authorization-v1.schema.json") -Now $issued
}
Write-Output ([string]$policy.comment_marker)
Write-Output $documentText
