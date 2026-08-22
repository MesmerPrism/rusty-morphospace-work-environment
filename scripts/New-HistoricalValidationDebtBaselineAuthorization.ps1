param(
    [Parameter(Mandatory)][string]$BaselinePath,
    [Parameter(Mandatory)][string]$AuthorizationId,
    [Parameter(Mandatory)][string]$AuditId,
    [Parameter(Mandatory)][string]$IssuedAt,
    [Parameter(Mandatory)][string]$ExpiresAt,
    [string]$PrivateKeyPemPath = "",
    [string]$CertificateThumbprint = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (($PrivateKeyPemPath -eq '') -eq ($CertificateThumbprint -eq '')) { throw 'Specify exactly one external signing source.' }
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceHistoricalValidationDebtBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/ExternalOwnerAuthorization.psm1') -Force
$baselineFullPath = (Resolve-Path -LiteralPath $BaselinePath -ErrorAction Stop).Path
$bytePreflight = & (Join-Path $PSScriptRoot 'Test-CanonicalTextBytes.ps1') -EvidencePath $baselineFullPath -Json -NoThrow | ConvertFrom-Json -Depth 12
if ($bytePreflight.advisory_status -cne 'pass') {
    throw "Historical-debt baseline byte preflight failed: $($bytePreflight.reason_codes -join ', ')."
}
$baselineBytes = [IO.File]::ReadAllBytes($baselineFullPath)
$baseline = ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $baselineBytes -Context 'Historical-debt baseline signing input'
$baselineSchema = Join-Path $root 'schemas/historical-validation-debt-baseline-v1.schema.json'
if (-not (Test-Json -Json (ConvertTo-MorphospaceCanonicalJson -Value $baseline) -SchemaFile $baselineSchema -ErrorAction Stop)) {
    throw 'Historical-debt baseline signing input failed its closed schema.'
}
$baselineLeaf = Split-Path -Leaf $baselineFullPath
$baselineDirectory = Split-Path -Parent $baselineFullPath
$baselineIdFromPath = Split-Path -Leaf $baselineDirectory
$historicalDebtDirectory = Split-Path -Parent $baselineDirectory
$receiptsDirectory = Split-Path -Parent $historicalDebtDirectory
if ($baselineLeaf -cne 'baseline.json' -or (Split-Path -Leaf $historicalDebtDirectory) -cne 'historical-validation-debt' -or
    (Split-Path -Leaf $receiptsDirectory) -cne 'receipts' -or [string]$baseline.baseline_id -cne $baselineIdFromPath -or
    [string]$baseline.authorization.path -cne "receipts/historical-validation-debt/$baselineIdFromPath/authorization.json") {
    throw 'Historical-debt signing input is not the canonical immutable baseline and authorization sibling pair.'
}
try {
    $issued = [datetimeoffset]::ParseExact($IssuedAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    $expires = [datetimeoffset]::ParseExact($ExpiresAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
} catch {
    throw 'Historical-debt authorization timestamps must use second-precision UTC ISO-8601 form.'
}
$policy = Read-ExternalOwnerAuthorizationPolicy `
    -Path (Join-Path $root 'config/external-owner-authorization.json') `
    -SchemaPath (Join-Path $root 'schemas/external-owner-authorization-policy-v1.schema.json')
if ($issued -lt [datetimeoffset]::UtcNow.AddSeconds(-[int]$policy.max_authorization_age_seconds) -or
    $issued -gt [datetimeoffset]::UtcNow.AddSeconds([int]$policy.max_future_skew_seconds)) {
    throw 'Historical-debt authorization issuance is outside the pinned freshness window.'
}
if ($expires -le $issued -or $expires -gt $issued.AddSeconds([int]$policy.max_authorization_age_seconds)) {
    throw 'Historical-debt authorization expiry must be after issuance and within the pinned maximum age.'
}
$payload = New-MorphospaceHistoricalValidationDebtAuthorizationPayload `
    -Baseline $baseline -BaselineSha256 (Get-MorphospaceSha256Bytes -Bytes $baselineBytes) `
    -AuthorizationId $AuthorizationId -AuditId $AuditId -IssuedAt $IssuedAt -ExpiresAt $ExpiresAt -IssuerId ([string]$policy.issuer_id)
[byte[]]$canonical = Get-CanonicalAuthorizationBytes -Payload $payload
$rsa = $null
try {
    if ($PrivateKeyPemPath) {
        $rsa = [Security.Cryptography.RSA]::Create()
        $rsa.ImportFromPem((Get-Content -Raw -LiteralPath $PrivateKeyPemPath))
    } else {
        if ($CertificateThumbprint -cnotmatch '^[0-9A-Fa-f]{40}$') { throw 'Certificate thumbprint is malformed.' }
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('My','CurrentUser')
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        try { $certs = @($store.Certificates | Where-Object Thumbprint -eq $CertificateThumbprint) } finally { $store.Dispose() }
        if ($certs.Count -ne 1 -or -not $certs[0].HasPrivateKey) { throw 'Exactly one signing certificate with a private key is required.' }
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certs[0])
    }
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    if ($fingerprint -cne [string]$policy.public_key_spki_sha256) { throw 'External signing key does not equal the pinned public key.' }
    [byte[]]$signature = $rsa.SignData($canonical, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss)
} finally {
    if ($null -ne $rsa) { $rsa.Dispose() }
}
[ordered]@{
    schema = 'rusty.morphospace.workflow.historical_validation_debt_baseline_authorization.v1'
    payload = $payload
    signature = [ordered]@{
        algorithm = 'RSA-PSS-SHA256'
        public_key_spki_sha256 = [string]$policy.public_key_spki_sha256
        value_base64 = [Convert]::ToBase64String($signature)
    }
} | ConvertTo-Json -Depth 32 -Compress
