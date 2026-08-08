param(
    [Parameter(Mandatory)][string]$DraftPath,
    [Parameter(Mandatory)][string]$AuthorizationId,
    [Parameter(Mandatory)][string]$IssuedAt,
    [Parameter(Mandatory)][string]$ExpiresAt,
    [Parameter(Mandatory)][string]$OutPath,
    [string]$PrivateKeyPemPath = '',
    [string]$CertificateThumbprint = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (($PrivateKeyPemPath -eq '') -eq ($CertificateThumbprint -eq '')) { throw 'Specify exactly one external signing source.' }

Import-Module (Join-Path $PSScriptRoot 'ReconcilePreparedPushTransactionSuffix.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\ExternalOwnerAuthorization.psm1') -Force

$repoRoot = Split-Path $PSScriptRoot -Parent
$draft = Read-MorphospaceProtocolJson (Resolve-Path -LiteralPath $DraftPath)
$scope = Get-PreparedPushSuffixAuthorizationScope $draft
[byte[]]$scopeBytes = Get-CanonicalAuthorizationBytes $scope
$scopeHash = Get-ExternalOwnerSha256 $scopeBytes
$policy = Read-ExternalOwnerAuthorizationPolicy `
    -Path (Join-Path $repoRoot 'config\external-owner-authorization.json') `
    -SchemaPath (Join-Path $repoRoot 'schemas\external-owner-authorization-policy-v1.schema.json')
try {
    $issued = [datetimeoffset]::ParseExact($IssuedAt,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
    $expires = [datetimeoffset]::ParseExact($ExpiresAt,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
} catch { throw 'IssuedAt and ExpiresAt must use strict UTC seconds.' }
if ($expires -le $issued -or $expires -gt $issued.AddSeconds([int]$policy.max_authorization_age_seconds)) { throw 'Authorization expiry is outside the policy window.' }

$payload = [pscustomobject][ordered]@{
    issuer_id=[string]$policy.issuer_id
    authorization_id=$AuthorizationId
    project_id=[string]$draft.project_id
    unit_id=[string]$draft.unit_id
    bundle_id=[string]$draft.bundle_id
    scope_sha256=$scopeHash
    issued_at=$IssuedAt
    expires_at=$ExpiresAt
    decision='authorize-prepared-push-transaction-suffix-reconciliation'
    limitations=@(
        'matching_pending_bundle_only',
        'preserve_existing_evidence_bytes',
        'workflow_state_only',
        'git_mutation=false',
        'acceptance_mutation=false',
        'publication_authority=false'
    )
}
[byte[]]$payloadBytes = Get-CanonicalAuthorizationBytes $payload
$rsa = $null
try {
    if ($PrivateKeyPemPath) {
        $rsa = [Security.Cryptography.RSA]::Create()
        $rsa.ImportFromPem((Get-Content -Raw -LiteralPath (Resolve-Path -LiteralPath $PrivateKeyPemPath)))
    } else {
        $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint"
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
        if ($null -eq $rsa) { throw 'Selected certificate has no RSA private key.' }
    }
    $actualFingerprint = [RustyMorphospace.ExternalOwnerCrypto]::SpkiSha256($rsa.ExportSubjectPublicKeyInfoPem())
    if ($actualFingerprint -cne [string]$policy.public_key_spki_sha256) { throw 'Signing key does not equal the pinned external owner key.' }
    [byte[]]$signature = $rsa.SignData($payloadBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
} finally {
    if ($null -ne $rsa) { $rsa.Dispose() }
}

$signed = $draft | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
$signed.authorization = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.prepared_push_transaction_suffix_authorization.v1'
    payload=$payload
    signature=[pscustomobject][ordered]@{
        algorithm='RSA-PSS-SHA256'
        public_key_spki_sha256=[string]$policy.public_key_spki_sha256
        value_base64=[Convert]::ToBase64String($signature)
    }
}
$schema = Join-Path $repoRoot 'schemas\prepared-push-transaction-suffix-reconciliation-v1.schema.json'
$json = $signed | ConvertTo-Json -Depth 100
if (-not (Test-Json -Json $json -SchemaFile $schema -ErrorAction Stop)) { throw 'Signed prepared-push suffix reconciliation failed its schema.' }
$target = [IO.Path]::GetFullPath($OutPath)
if ([IO.File]::Exists($target)) { throw 'Signed authorization output already exists.' }
$parent = [IO.Path]::GetDirectoryName($target)
if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($target,$json + "`n",[Text.UTF8Encoding]::new($false))
[pscustomobject][ordered]@{
    path=$target
    sha256=Get-MorphospaceFileSha256 $target
    scope_sha256=$scopeHash
    authorization_id=$AuthorizationId
} | ConvertTo-Json
