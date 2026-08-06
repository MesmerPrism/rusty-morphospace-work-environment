param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$AuthorizationId,
    [Parameter(Mandatory)][string]$IssuedAt,
    [Parameter(Mandatory)][string]$ExpiresAt,
    [string]$PrivateKeyPemPath = "",
    [string]$CertificateThumbprint = ""
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (($PrivateKeyPemPath -eq "") -eq ($CertificateThumbprint -eq "")) { throw "Specify exactly one external signing source." }
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot "lib/ExternalOwnerAuthorization.psm1") -Force
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
Write-Output ([string]$policy.comment_marker)
Write-Output ($document | ConvertTo-Json -Depth 30 -Compress)
