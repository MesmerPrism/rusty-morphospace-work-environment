param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-GitTest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Test Git command failed ($($Arguments -join ' ')): $($output -join "`n")"
    }
    return (@($output) -join "`n").Trim()
}

function Write-Utf8 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent)
    }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Get-GitBlobBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ObjectId
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = @(
        Get-Command git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    )[0].Source
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @("cat-file", "blob", $ObjectId)) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $memory = [IO.MemoryStream]::new()
    try {
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Test Git blob read failed: $stderr"
        }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        & $Operation | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Label rejected for the wrong reason: $($_.Exception.Message)"
        }
        return
    }
    throw "$Label unexpectedly passed."
}

$temp = Join-Path (
    [IO.Path]::GetTempPath()
) ("external-authority-github-adapter-" + [guid]::NewGuid().ToString("N"))
$remoteRoot = Join-Path $temp "remote.git"
$seedRoot = Join-Path $temp "seed"
$trustedRoot = Join-Path $temp "trusted"
$markerPath = Join-Path $temp "candidate-executed.txt"
$adapter = Join-Path $PSScriptRoot "Invoke-ExternalValidationAuthorityForGitHub.ps1"
$adapterSource = Get-Content -Raw $adapter
$workflowSource = Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) ".github/workflows/static-admission.yml")
# YAML permissions and step environment entries are literal configuration.
if ([regex]::Matches($workflowSource, '(?m)^\s*permissions:').Count -ne 1 -or
    $workflowSource -cnotmatch '(?m)^permissions:\r?\n  issues: read\r?\n\r?\n' -or
    [regex]::Matches($workflowSource, 'STATIC_ADMISSION_COMMENTS_TOKEN: \$\{\{ github.token \}\}').Count -ne 1 -or
    $workflowSource -cnotmatch '(?s)name: Inspect pull request objects with the pinned base verifier.*env:.*STATIC_ADMISSION_COMMENTS_TOKEN:' -or
    $workflowSource -cnotmatch '-RequireAuthenticatedComments') {
    throw "Static workflow must confine its required read-only credential to the trusted reader step."
}
if (
    -not $adapterSource.Contains('.ReadAsync($buffer,0,$buffer.Length,$deadline.Token)') -or
    $adapterSource.Contains('while(($n=$stream.Read(')
) {
    throw "Public comment body reads must observe the shared HTTP deadline."
}
$repository = "example/static-admission-fixture"
$pullRequestNumber = "7"
$rsa = [Security.Cryptography.RSA]::Create(3072)

# Exercise the actual reader with an in-memory HTTP transport. Production has
# no endpoint override; even hostile Link/Location headers cannot select a URL.
$adapterAst = [Management.Automation.Language.Parser]::ParseFile($adapter, [ref]$null, [ref]$null)
foreach ($name in @("Get-CommentFetchRetryPlan", "Get-PublicIssueComments", "New-GitStartInfo", "Test-ForbiddenGitEnvironmentName")) {
    $definition = $adapterAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false)
    Set-Item -LiteralPath "Function:$name" -Value $definition.Body.GetScriptBlock()
}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class StaticCommentTestHandler : HttpMessageHandler {
    public readonly Queue<HttpResponseMessage> Responses = new Queue<HttpResponseMessage>();
    public readonly List<string> Requests = new List<string>();
    public readonly List<string> Authorizations = new List<string>();
    public bool FailTransport;
    public int DelayBeforeResponseMilliseconds;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Requests.Add(request.Method + " " + request.RequestUri.AbsoluteUri);
        Authorizations.Add(request.Headers.Authorization == null ? "" : request.Headers.Authorization.ToString());
        if (FailTransport) throw new HttpRequestException("DO-NOT-LOG-response-secret");
        await Task.Delay(DelayBeforeResponseMilliseconds, token);
        if (Responses.Count == 0) throw new InvalidOperationException("Unexpected additional HTTP request");
        return Responses.Dequeue();
    }
}
public sealed class StaticCommentSlowBody : Stream {
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] b, int o, int n) => throw new Exception("Synchronous body read is forbidden");
    public override async Task<int> ReadAsync(byte[] b, int o, int n, CancellationToken token) { await Task.Delay(30000, token); return 0; }
    public override void Flush() => throw new NotSupportedException();
    public override long Seek(long n, SeekOrigin o) => throw new NotSupportedException();
    public override void SetLength(long n) => throw new NotSupportedException();
    public override void Write(byte[] b, int o, int n) => throw new NotSupportedException();
}
'@
function New-CommentResponse([int]$Status, [string]$Body = "[]", [hashtable]$Headers = @{}) {
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    $response.Content = [Net.Http.StringContent]::new($Body)
    foreach ($name in $Headers.Keys) { [void]$response.Headers.TryAddWithoutValidation($name, [string]$Headers[$name]) }
    return $response
}
function Invoke-CommentTransportCase([Net.Http.HttpResponseMessage[]]$Responses, [string]$Reject = "", [int]$ExpectedRequests = 1, [int]$MaximumBytes = 1048576, [string]$Token = "fixture_token") {
    $handler = [StaticCommentTestHandler]::new()
    foreach ($response in $Responses) { $handler.Responses.Enqueue($response) }
    $AllowLocalTestRemote = $true
    $invoke = { Get-PublicIssueComments "example/repository" 7 "" 1000 $MaximumBytes $Token $handler }
    if ($Reject) { Assert-Rejected $invoke $Reject "HTTP transport case" }
    else { $null = & $invoke }
    if ($handler.Requests.Count -ne $ExpectedRequests) { throw "HTTP case made $($handler.Requests.Count) requests, expected $ExpectedRequests." }
    foreach ($request in $handler.Requests) {
        if ($request -cnotmatch '^GET https://api\.github\.com/repos/example/repository/issues/7/comments\?per_page=100&page=[0-9]+$') { throw "Comment request escaped the fixed read-only origin or path." }
    }
    $expectedAuthorization = if ($Token) { "Bearer $Token" } else { "" }
    foreach ($authorization in $handler.Authorizations) {
        if ($authorization -cne $expectedAuthorization) { throw "Reader silently changed authentication across requests." }
    }
}
$now = [datetimeoffset]::Parse("2026-01-01T00:00:00Z")
foreach ($case in @(
    @{status=403;headers=@{};attempt=1;delay=$null},
    @{status=401;headers=@{};attempt=1;delay=$null},
    @{status=429;headers=@{};attempt=1;delay=60L},
    @{status=403;headers=@{"x-ratelimit-remaining"="0";"x-ratelimit-reset"="1767229200"};attempt=1;delay=3601L},
    @{status=403;headers=@{"x-ratelimit-remaining"="0"};attempt=1;delay=$null},
    @{status=403;headers=@{"x-ratelimit-remaining"="0";"x-ratelimit-reset"="1767225602";"retry-after"="5"};attempt=1;delay=5L},
    @{status=403;headers=@{"retry-after"="Thu, 01 Jan 2026 00:00:04 GMT"};attempt=1;delay=4L},
    @{status=503;headers=@{};attempt=1;delay=1L},
    @{status=503;headers=@{};attempt=2;delay=2L},
    @{status=503;headers=@{};attempt=3;delay=$null},
    @{status=503;headers=@{"x-ratelimit-remaining"="0";"x-ratelimit-reset"="1767229200"};attempt=1;delay=3601L},
    @{status=503;headers=@{"retry-after"="garbage-secret"};attempt=1;delay=$null},
    @{status=503;headers=@{"x-ratelimit-reset"="garbage-secret"};attempt=1;delay=$null},
    @{status=503;headers=@{"retry-after"="9223372036854775807"};attempt=1;delay=[long]::MaxValue}
)) {
    $response = New-CommentResponse $case.status "DO-NOT-LOG-response-secret" $case.headers
    try {
        $plan = Get-CommentFetchRetryPlan $response $case.attempt $now
        if ($plan.delay_seconds -cne $case.delay) { throw "Wrong retry plan for HTTP $($case.status): $($plan.delay_seconds)." }
        if ($plan.detail -match 'secret') { throw "Retry diagnostics exposed untrusted content." }
    } finally { $response.Dispose() }
}
Invoke-CommentTransportCase @((New-CommentResponse 200))
Invoke-CommentTransportCase @((New-CommentResponse 200)) -Token ""
Invoke-CommentTransportCase @((New-CommentResponse 503), (New-CommentResponse 200)) -ExpectedRequests 2
Invoke-CommentTransportCase @((New-CommentResponse 503), (New-CommentResponse 503), (New-CommentResponse 503)) -ExpectedRequests 3 -Reject 'HTTP 503; attempt=3'
Invoke-CommentTransportCase @((New-CommentResponse 403 "DO-NOT-LOG-response-secret" @{"x-ratelimit-limit"="60";"x-ratelimit-remaining"="0";"x-ratelimit-reset"="9223372036854775807"})) -Reject 'HTTP 403.*x-ratelimit-limit=60.*x-ratelimit-remaining=0'
Invoke-CommentTransportCase @((New-CommentResponse 401)) -Reject 'HTTP 401'
Invoke-CommentTransportCase @((New-CommentResponse 429)) -Reject 'HTTP 429'
Invoke-CommentTransportCase @((New-CommentResponse 302 "[]" @{Location="https://attacker.invalid/steal"})) -Reject 'HTTP 302'
Invoke-CommentTransportCase @((New-CommentResponse 200 "[]" @{Link='<https://attacker.invalid/steal>; rel="next"'}), (New-CommentResponse 200)) -ExpectedRequests 2
Invoke-CommentTransportCase @((New-CommentResponse 200 '[{"duplicate":1,"duplicate":2}]')) -Reject 'Duplicate'
Invoke-CommentTransportCase @((New-CommentResponse 200 "[1,2,3]")) -MaximumBytes 4 -Reject 'size bound'
$emptyPages = @(1..12 | ForEach-Object { New-CommentResponse 200 "[]" @{Link='<https://attacker.invalid/steal>; rel="next"'} })
Invoke-CommentTransportCase $emptyPages -ExpectedRequests 11 -Reject 'page bound'
$handler = [StaticCommentTestHandler]::new()
$handler.FailTransport = $true
$AllowLocalTestRemote = $true
Assert-Rejected { Get-PublicIssueComments "example/repository" 7 "" 1000 1048576 "fixture_token" $handler } '^Public comment fetch failed during transport or exceeded the shared 20-second deadline\.$' "sanitized network error"
$AllowLocalTestRemote = $false
Assert-Rejected { Get-PublicIssueComments "example/repository" 7 "" 1000 1048576 "" ([StaticCommentTestHandler]::new()) } 'test-only' "production HTTP injection"
$handler = [StaticCommentTestHandler]::new()
$handler.DelayBeforeResponseMilliseconds = 10000
$slowResponse = New-CommentResponse 200
$slowResponse.Content.Dispose()
$slowResponse.Content = [Net.Http.StreamContent]::new([StaticCommentSlowBody]::new())
$handler.Responses.Enqueue($slowResponse)
$AllowLocalTestRemote = $true
$watch = [Diagnostics.Stopwatch]::StartNew()
Assert-Rejected { Get-PublicIssueComments "example/repository" 7 "" 1000 1048576 "fixture_token" $handler } 'canceled|cancelled|deadline' "shared header/body deadline"
if ($watch.Elapsed.TotalSeconds -gt 28) { throw "Body read restarted rather than shared the HTTP deadline." }
$AllowLocalTestRemote = $false

# A child is credential-free even if a caller reintroduces the step variable.
$ForbiddenGitEnvironmentVariables = @()
$env:STATIC_ADMISSION_COMMENTS_TOKEN = "fixture_token"
try {
    $start = New-GitStartInfo $PSScriptRoot
    if ($start.Environment.ContainsKey("STATIC_ADMISSION_COMMENTS_TOKEN")) { throw "Git child inherited the comment token." }
} finally { Remove-Item Env:STATIC_ADMISSION_COMMENTS_TOKEN }

try {
    [void](New-Item -ItemType Directory -Path $temp)
    [void](New-Item -ItemType Directory -Path $remoteRoot)
    [void](New-Item -ItemType Directory -Path $seedRoot)
    [void](Invoke-GitTest $remoteRoot @("init", "--bare"))
    [void](Invoke-GitTest $seedRoot @("init", "--initial-branch=main"))
    [void](Invoke-GitTest $seedRoot @("config", "user.name", "Static Admission Test"))
    [void](Invoke-GitTest $seedRoot @("config", "user.email", "static-admission@example.invalid"))
    [void](Invoke-GitTest $seedRoot @("config", "core.autocrlf", "false"))
    Write-Utf8 (Join-Path $seedRoot ".fixture-root") "fixture root`n"
    [void](Invoke-GitTest $seedRoot @("add", ".fixture-root"))
    [void](Invoke-GitTest $seedRoot @("commit", "-m", "fixture root"))
    $requiredAncestor = Invoke-GitTest $seedRoot @("rev-parse", "HEAD")
    $fixtureRootTree = Invoke-GitTest $seedRoot @("rev-parse", "HEAD^{tree}")
    $approvalAnchor = Invoke-GitTest $seedRoot @("commit-tree",$fixtureRootTree,"-m","independent approval anchor")

    foreach ($directory in @("config", "schemas", "scripts", "scripts/lib")) {
        [void](New-Item -ItemType Directory -Path (Join-Path $seedRoot $directory))
    }
    Copy-Item -LiteralPath (
        Join-Path $PSScriptRoot "Test-ExternalValidationAuthority.ps1"
    ) -Destination (
        Join-Path $seedRoot "scripts/Test-ExternalValidationAuthority.ps1"
    )
    $fixtureVerifierPath = Join-Path $seedRoot "scripts/Test-ExternalValidationAuthority.ps1"
    $fixtureVerifierSource = Get-Content -Raw $fixtureVerifierPath
    $fixtureVerifierAst = [Management.Automation.Language.Parser]::ParseInput($fixtureVerifierSource, [ref]$null, [ref]$null)
    $credentialProbe = @'

if (Test-Path Env:STATIC_ADMISSION_COMMENTS_TOKEN) { throw "Verifier inherited the comment token." }
if (Get-Variable commentReadToken -ErrorAction SilentlyContinue) { throw "Verifier resolved the parent comment token variable." }

'@
    $fixtureVerifierSource = $fixtureVerifierSource.Insert($fixtureVerifierAst.ParamBlock.Extent.EndOffset, $credentialProbe)
    Write-Utf8 $fixtureVerifierPath $fixtureVerifierSource
    foreach ($schemaName in @(
        "external-validation-authority-assessment-v1.schema.json",
        "external-validation-authority-policy-v1.schema.json",
        "external-owner-authorization-policy-v1.schema.json",
        "external-owner-authorization-v1.schema.json",
        "external-owner-authorization-request-v1.schema.json"
    )) {
        Copy-Item -LiteralPath (
            Join-Path (Split-Path -Parent $PSScriptRoot) "schemas/$schemaName"
        ) -Destination (Join-Path $seedRoot "schemas/$schemaName")
    }
    Copy-Item (Join-Path $PSScriptRoot "lib/ExternalOwnerAuthorization.psm1") (Join-Path $seedRoot "scripts/lib/ExternalOwnerAuthorization.psm1")
    $fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    $publicPem=$rsa.ExportSubjectPublicKeyInfoPem().Replace("`r","")
    $fixturePolicySchemaPath=Join-Path $seedRoot "schemas/external-owner-authorization-policy-v1.schema.json"
    $fixturePolicySchema=Get-Content -Raw $fixturePolicySchemaPath
    $fixturePolicySchema=$fixturePolicySchema.Replace('mesmerprism-owner-policy-authority-v1','test-owner-authority-v1').Replace('MesmerPrism','Owner').Replace('rusty-morphospace-external-owner-authorization:v1','test-external-owner:v1').Replace('e6ceb8c9bb2d3c178b28f15b9cd47ff1229e13584cd9c3b7dec1c2cda2f476e6',$fingerprint)
    Write-Utf8 $fixturePolicySchemaPath $fixturePolicySchema
    Write-Utf8 (Join-Path $seedRoot "config/external-owner-authorization.json") (([ordered]@{schema="rusty.morphospace.workflow.external_owner_authorization_policy.v1";issuer_id="test-owner-authority-v1";owner_login="Owner";comment_marker="test-external-owner:v1";max_authorization_age_seconds=86400;max_future_skew_seconds=300;maximum_comments=1000;maximum_response_bytes=1048576;maximum_comment_bytes=65536;public_key_spki_sha256=$fingerprint;public_key_pem=$publicPem}|ConvertTo-Json -Depth 10))
    $approvedContent = "approved protected fixture`n"
    $approvedHash = Get-Sha256 ([Text.UTF8Encoding]::new($false).GetBytes($approvedContent))
    Write-Utf8 (Join-Path $seedRoot "config/external-validation-authority.json") @"
{
  "schema": "rusty.morphospace.workflow.external_validation_authority_policy.v1",
  "policy_id": "static-admission-fixture-v1",
  "repository": "$repository",
  "mandatory_protected_paths": [
    "config/external-validation-authority.json"
  ],
  "protected_rules": [
    {
      "rule_id": "protected-fixture",
      "match": "prefix",
      "path": "protected/"
    }
  ],
  "approved_change_sets": [
    {
      "approval_id": "exact-approved-fixture-v1",
      "required_ancestor": "$approvalAnchor",
      "changed_paths": ["protected/approved.txt"],
      "artifacts": [
        {"path":"protected/approved.txt","state":"present","mode":"100644","size_bytes":27,"sha256":"$approvedHash"}
      ],
      "status": "approved"
    }
  ],
  "status": "active"
}
"@
    [void](Invoke-GitTest $seedRoot @("add", "."))
    [void](Invoke-GitTest $seedRoot @("commit", "-m", "trusted base"))
    $baseCommit = Invoke-GitTest $seedRoot @("rev-parse", "HEAD")
    $baseTree = Invoke-GitTest $seedRoot @("rev-parse", "HEAD^{tree}")
    $verifierEntry = Invoke-GitTest $seedRoot @(
        "ls-tree", "HEAD", "--", "scripts/Test-ExternalValidationAuthority.ps1"
    )
    if ($verifierEntry -cnotmatch "^100644 blob ([0-9a-f]{40})`t") {
        throw "Fixture verifier blob entry is malformed."
    }
    $verifierSha256 = Get-Sha256 (Get-GitBlobBytes $seedRoot $Matches[1])
    [void](Invoke-GitTest $seedRoot @("remote", "add", "origin", $remoteRoot))
    [void](Invoke-GitTest $seedRoot @("push", "origin", "main"))

    [void](Invoke-GitTest $seedRoot @("checkout", "-b", "unprotected"))
    $escapedMarker = $markerPath.Replace("'", "''")
    Write-Utf8 (Join-Path $seedRoot "candidate/never-run.ps1") (
        "[IO.File]::WriteAllText('$escapedMarker', 'executed')`n" +
        "throw 'Candidate code executed.'`n"
    )
    Write-Utf8 (Join-Path $seedRoot "docs/note.md") "ordinary unprotected change`n"
    [void](Invoke-GitTest $seedRoot @("add", "."))
    [void](Invoke-GitTest $seedRoot @("commit", "-m", "unprotected candidate"))
    $unprotectedHead = Invoke-GitTest $seedRoot @("rev-parse", "HEAD")
    $unprotectedTree = Invoke-GitTest $seedRoot @("rev-parse", "HEAD^{tree}")
    $unprotectedMerge = Invoke-GitTest $seedRoot @("commit-tree", $unprotectedTree, "-p", $baseCommit, "-p", $unprotectedHead, "-m", "unprotected pull request merge")
    [void](Invoke-GitTest $seedRoot @("push", "origin", "${unprotectedHead}:refs/pull/$pullRequestNumber/head", "${unprotectedMerge}:refs/pull/$pullRequestNumber/merge"))

    [void](Invoke-GitTest $temp @("clone", "--no-local", $remoteRoot, $trustedRoot))
    [void](Invoke-GitTest $trustedRoot @("checkout", "--detach", $baseCommit))
    $commentsPath=Join-Path $temp "comments.json";Write-Utf8 $commentsPath "[]"
    $commonArguments = @{RepositoryRoot=$trustedRoot;Repository=$repository;PullRequestNumber=$pullRequestNumber;BaseCommit=$baseCommit;HeadCommit=$unprotectedHead;PinnedVerifierCommit=$baseCommit;PinnedVerifierTree=$baseTree;PinnedVerifierPath="scripts/Test-ExternalValidationAuthority.ps1";PinnedVerifierSha256=$verifierSha256;RemoteUrl=$remoteRoot;CommentsJsonPath=$commentsPath;AllowLocalTestRemote=$true}
    Assert-Rejected { & $adapter @commonArguments -RequireAuthenticatedComments } 'requires its read-only workflow token' "missing hosted credential"
    foreach ($invalidToken in @('', ' ', "`t", 'two words', ' leading', 'trailing ', "invalid`ncredential", "trailing`n", "trailing`r", "invalid`r`nInjected: value", ("control" + [char]1 + "value"), ("format" + [char]0x200b + "value"), ("space" + [char]0x00a0 + "value"), ('x' * 4097), 'a,b', 'a"b', "a'b", 'a:b', 'a;b', '=', '==', '=abc', 'abc=def', 'abc==def', 'café')) {
        $env:STATIC_ADMISSION_COMMENTS_TOKEN = $invalidToken
        Assert-Rejected { & $adapter @commonArguments -RequireAuthenticatedComments } 'requires its read-only workflow token|credential has an invalid format' "unsafe credential value"
        if (Test-Path Env:STATIC_ADMISSION_COMMENTS_TOKEN) { throw "Rejected credential remained in the environment." }
    }
    # Synthetic values only: classic spelling, current JWT-shaped spelling,
    # opaque punctuation without a known prefix, and the transport size ceiling.
    # Passing these proves safe transport, not that GitHub would authorize them.
    foreach ($opaqueToken in @('fixture_token', ('ghs_123456_' + ('a' * 170) + '.' + ('b-' * 85) + '.' + ('c_' * 85)), 'opaque.value-with+slash/tilde~', 'opaque=', 'opaque==', 'x', ('x' * 4096), (('x' * 4095) + '='))) {
        $env:STATIC_ADMISSION_COMMENTS_TOKEN = $opaqueToken
        $ordinaryAssessment=(@(& $adapter @commonArguments -RequireAuthenticatedComments)-join "`n")|ConvertFrom-Json -Depth 30
        if (Test-Path Env:STATIC_ADMISSION_COMMENTS_TOKEN) { throw "Adapter retained the credential environment variable." }
        Invoke-CommentTransportCase @((New-CommentResponse 200)) -Token $opaqueToken
    }
    if([string]$ordinaryAssessment.decision -cne "unprotected"){throw "Ordinary unprotected v1 fixture returned the wrong decision."}

    [void](Invoke-GitTest $seedRoot @("checkout", "-b", "approved-work", $baseCommit))
    Write-Utf8 (Join-Path $seedRoot "protected/approved.txt") $approvedContent
    [void](Invoke-GitTest $seedRoot @("add", "."));$approvedTree=Invoke-GitTest $seedRoot @("write-tree")
    $approvedHead=Invoke-GitTest $seedRoot @("commit-tree",$approvedTree,"-p",$baseCommit,"-p",$approvalAnchor,"-m","approved protected candidate")
    $approvedMerge=Invoke-GitTest $seedRoot @("commit-tree",$approvedTree,"-p",$baseCommit,"-p",$approvedHead,"-m","approved pull request merge")
    [void](Invoke-GitTest $seedRoot @("push","--force","origin","${approvedHead}:refs/pull/$pullRequestNumber/head","${approvedMerge}:refs/pull/$pullRequestNumber/merge"))
    $approvedArguments=@{}+$commonArguments;$approvedArguments.HeadCommit=$approvedHead
    $approvedAssessment=(@(& $adapter @approvedArguments)-join "`n")|ConvertFrom-Json -Depth 30
    if([string]$approvedAssessment.decision -cne "approved-change-set" -or [string]$approvedAssessment.approval_id -cne "exact-approved-fixture-v1"){throw "Exact base-approved protected fixture returned the wrong decision."}

    [void](Invoke-GitTest $seedRoot @("read-tree", "--reset", "-u", $baseCommit))
    [void](Invoke-GitTest $seedRoot @("checkout", "-b", "candidate", $baseCommit))
    Write-Utf8 (Join-Path $seedRoot "protected/gate.ps1") "throw 'never execute candidate'`n"
    [void](Invoke-GitTest $seedRoot @("add", "."));[void](Invoke-GitTest $seedRoot @("commit", "-m", "external owner candidate"))
    $headCommit = Invoke-GitTest $seedRoot @("rev-parse", "HEAD")
    $headTree = Invoke-GitTest $seedRoot @("rev-parse", "HEAD^{tree}")
    $mergeCommit = Invoke-GitTest $seedRoot @(
        "commit-tree", $headTree, "-p", $baseCommit, "-p", $headCommit,
        "-m", "synthetic pull request merge"
    )
    [void](Invoke-GitTest $seedRoot @(
        "push", "--force", "origin",
        "${headCommit}:refs/pull/$pullRequestNumber/head",
        "${mergeCommit}:refs/pull/$pullRequestNumber/merge"
    ))

    $commonArguments.HeadCommit=$headCommit
    $commentsPath=Join-Path $temp "comments.json";Write-Utf8 $commentsPath "[]"
    $requestPath=Join-Path $temp "request.json";$ownerArguments=@{}+$commonArguments;$ownerArguments.CommentsJsonPath=$commentsPath;$ownerArguments.AuthorizationRequestPath=$requestPath
    try{& $adapter @ownerArguments | Out-Null;throw "Missing authorization unexpectedly passed."}catch{if($_.Exception.Message -notmatch "canonical request was emitted"){throw}}
    [byte[]]$requestBytes=[IO.File]::ReadAllBytes($requestPath)
    if($requestBytes -contains 0x0D){throw "Authorization request producer emitted a carriage return."}
    if($requestBytes.Length -ge 3 -and $requestBytes[0] -eq 0xEF -and $requestBytes[1] -eq 0xBB -and $requestBytes[2] -eq 0xBF){throw "Authorization request producer emitted a UTF-8 BOM."}
    $requestText=Get-Content -Raw $requestPath
    $request=$requestText|ConvertFrom-Json -Depth 30 -DateKind String
    if([string]$request.schema -cne "rusty.morphospace.workflow.external_owner_authorization_request.v1"){throw "Wrong request schema."}
    Import-Module (Join-Path $PSScriptRoot "lib/ExternalOwnerAuthorization.psm1") -Force
    function New-TestComment([object]$Request=$request,[string]$Login="Owner",[int]$Id=91,[string]$AuthorizationId="authorization-00000001",[datetimeoffset]$Issued=[datetimeoffset]::UtcNow,[datetimeoffset]$Expires=([datetimeoffset]::UtcNow.AddHours(1)),[Security.Cryptography.RSA]$SigningKey=$rsa,[string]$KeyFingerprint=$fingerprint){$issuedText=$Issued.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");$expiresText=$Expires.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");$payload=New-ExternalOwnerAuthorizationPayload $Request $AuthorizationId $issuedText $expiresText;$sig=$SigningKey.SignData((Get-CanonicalAuthorizationBytes $payload),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss);$doc=[ordered]@{schema="rusty.morphospace.workflow.external_owner_authorization.v1";payload=$payload;signature=[ordered]@{algorithm="RSA-PSS-SHA256";public_key_spki_sha256=$KeyFingerprint;value_base64=[Convert]::ToBase64String($sig)}};return [ordered]@{id=$Id;created_at=$issuedText;updated_at=$issuedText;user=[ordered]@{login=$Login};body="test-external-owner:v1`n"+($doc|ConvertTo-Json -Depth 30 -Compress)}}
    function Invoke-OwnerCase([object[]]$Comments,[bool]$Pass,[string]$Label){Write-Utf8 $commentsPath ($Comments|ConvertTo-Json -Depth 40 -AsArray);if($Pass){$result=@(& $adapter @ownerArguments)-join "`n";$assessment=$result|ConvertFrom-Json -Depth 30;if([string]$assessment.decision -cne "external-owner-authorization"){throw "$Label returned wrong decision."};if((Get-ExternalOwnerSha256 (Get-CanonicalAuthorizationBytes $assessment)) -cne [string]$request.assessment_sha256){throw "$Label returned assessment bytes different from the signed request."}}else{Assert-Rejected {& $adapter @ownerArguments} ".+" $Label}}
    function Assert-FreshRequest([hashtable]$Arguments,[object[]]$Comments,[int]$ExpectedPullRequest,[string]$Label){Write-Utf8 $commentsPath ($Comments|ConvertTo-Json -Depth 40 -AsArray);Write-Utf8 $requestPath "stale request sentinel";Assert-Rejected {& $adapter @Arguments} "canonical request was emitted" $Label;$freshText=Get-Content -Raw $requestPath;if($freshText -ceq "stale request sentinel"){throw "$Label did not rewrite the canonical request file."};$fresh=$freshText|ConvertFrom-Json -Depth 30 -DateKind String;if([int]$fresh.pull_request_number -ne $ExpectedPullRequest){throw "$Label emitted a request for the wrong pull request."};return $fresh}
    $valid=New-TestComment
    Invoke-OwnerCase @($valid) $true "exact signed comment"
    Invoke-OwnerCase @($valid) $true "exact signed comment rerun"
    $crlfValid=$valid|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30 -DateKind String
    $crlfValid.body=$crlfValid.body.Replace("`n","`r`n")
    Invoke-OwnerCase @($crlfValid) $true "CRLF-persisted signed comment"
    $editedValid=$valid|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30 -DateKind String
    $editedValid.updated_at=([datetimeoffset]::ParseExact([string]$editedValid.created_at,"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).AddSeconds(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    Invoke-OwnerCase @($editedValid) $false "edited signed comment"
    Invoke-OwnerCase @($valid,(New-TestComment -Login "Other" -Id 92)) $true "foreign marker cannot suppress owner authorization"
    $busy=@($valid);for($i=1;$i -le 150;$i++){$busy += [ordered]@{id=1000+$i;created_at="2026-08-06T00:00:00Z";updated_at="2026-08-06T00:00:00Z";user=[ordered]@{login="Other"};body="unrelated discussion $i"}};Invoke-OwnerCase $busy $true "more than one public API page of unrelated comments"
    Invoke-OwnerCase @(New-TestComment -Login "Other") $false "wrong owner"
    Invoke-OwnerCase @($valid,$valid) $false "duplicate comment"
    foreach($property in @("head","artifacts","assessment_sha256")){ $bad=$request|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30 -DateKind String;if($property -eq "head"){$bad.head.commit="0"*40}elseif($property -eq "artifacts"){$bad.artifacts[0].sha256="0"*64}else{$bad.assessment.approval_id="different-external-owner-request";$bad.assessment_sha256=Get-ExternalOwnerSha256 (Get-CanonicalAuthorizationBytes $bad.assessment)};Invoke-OwnerCase @(New-TestComment -Request $bad) $false "wrong $property" }
    [void](Invoke-GitTest $seedRoot @("push","origin","${headCommit}:refs/pull/8/head","${mergeCommit}:refs/pull/8/merge"))
    $changedPr=@{}+$ownerArguments;$changedPr.PullRequestNumber="8"
    $changedRequest=Assert-FreshRequest $changedPr @($valid) 8 "same comment for changed PR"
    if((Get-ExternalOwnerSha256 (Get-CanonicalAuthorizationBytes $changedRequest)) -ceq (Get-ExternalOwnerSha256 (Get-CanonicalAuthorizationBytes $request))){throw "Changed PR reused the old canonical request."}
    $staleRequest=Assert-FreshRequest $ownerArguments @((New-TestComment -Issued ([datetimeoffset]::UtcNow.AddDays(-2)) -Expires ([datetimeoffset]::UtcNow.AddDays(-1)))) 7 "stale comment"
    if((Get-ExternalOwnerSha256 (Get-CanonicalAuthorizationBytes $staleRequest)) -cne (Get-ExternalOwnerSha256 (Get-CanonicalAuthorizationBytes $request))){throw "Stale authorization did not re-emit the current exact request."}
    Invoke-OwnerCase @(New-TestComment -Issued ([datetimeoffset]::UtcNow.AddMinutes(10))) $false "future comment"
    $other=[Security.Cryptography.RSA]::Create(3072);try{Invoke-OwnerCase @(New-TestComment -SigningKey $other) $false "bad signature";Invoke-OwnerCase @(New-TestComment -KeyFingerprint ("0"*64)) $false "bad key"}finally{$other.Dispose()}
    if (
        (Test-Path -LiteralPath $markerPath) -or
        (Test-Path -LiteralPath (Join-Path $trustedRoot "candidate")) -or
        (Test-Path -LiteralPath (Join-Path $trustedRoot "docs/note.md"))
    ) {
        throw "Candidate content was executed or checked out into the trusted base."
    }

    Write-Utf8 (Join-Path $seedRoot "docs/trusted-base-advance.md") "trusted base now contains candidate`n"
    [void](Invoke-GitTest $seedRoot @("add","."));[void](Invoke-GitTest $seedRoot @("commit","-m","trusted base advance"))
    $advancedBase=Invoke-GitTest $seedRoot @("rev-parse","HEAD")
    $consumedMerge=Invoke-GitTest $seedRoot @("commit-tree",$headTree,"-p",$advancedBase,"-p",$headCommit,"-m","consumed authorization merge")
    [void](Invoke-GitTest $seedRoot @("push","--force","origin","${advancedBase}:main","${headCommit}:refs/pull/$pullRequestNumber/head","${consumedMerge}:refs/pull/$pullRequestNumber/merge"))
    [void](Invoke-GitTest $trustedRoot @("fetch","origin","main"));[void](Invoke-GitTest $trustedRoot @("checkout","--detach",$advancedBase))
    $consumedArguments=@{}+$ownerArguments;$consumedArguments.BaseCommit=$advancedBase
    Assert-Rejected {& $adapter @consumedArguments} "consumed and inert" "trusted-base ancestry consumption"
    [void](Invoke-GitTest $trustedRoot @("checkout","--detach",$baseCommit))
    [void](Invoke-GitTest $seedRoot @("push","--force","origin","${baseCommit}:main","${mergeCommit}:refs/pull/$pullRequestNumber/merge"))

    $staleHead = @{} + $commonArguments
    $staleHead.HeadCommit = $baseCommit
    Assert-Rejected {
        & $adapter @staleHead
    } "Fetched pull request head does not equal" "stale event head"

    $retargetedBase = @{} + $commonArguments
    $retargetedBase.BaseCommit = $headCommit
    Assert-Rejected {
        & $adapter @retargetedBase
    } "Trusted checkout HEAD does not equal" "retargeted or stale event base"

    $oneParentMerge = Invoke-GitTest $seedRoot @(
        "commit-tree", $headTree, "-p", $baseCommit,
        "-m", "malformed one-parent merge"
    )
    [void](Invoke-GitTest $seedRoot @(
        "push", "--force", "origin",
        "${oneParentMerge}:refs/pull/$pullRequestNumber/merge"
    ))
    $oneParent = @{} + $commonArguments
    Assert-Rejected {
        & $adapter @oneParent
    } "exact ordered event base and head parents" "one-parent merge"

    $reversedMerge = Invoke-GitTest $seedRoot @(
        "commit-tree", $headTree, "-p", $headCommit, "-p", $baseCommit,
        "-m", "reversed pull request merge"
    )
    [void](Invoke-GitTest $seedRoot @(
        "push", "--force", "origin",
        "${reversedMerge}:refs/pull/$pullRequestNumber/merge"
    ))
    $reversed = @{} + $commonArguments
    Assert-Rejected {
        & $adapter @reversed
    } "exact ordered event base and head parents" "reversed merge parents"

    $wrongTreeMerge = Invoke-GitTest $seedRoot @(
        "commit-tree", $baseTree, "-p", $baseCommit, "-p", $headCommit,
        "-m", "exact parents with wrong merge tree"
    )
    [void](Invoke-GitTest $seedRoot @(
        "push", "--force", "origin",
        "${wrongTreeMerge}:refs/pull/$pullRequestNumber/merge"
    ))
    $wrongTree = @{} + $commonArguments
    Assert-Rejected {
        & $adapter @wrongTree
    } "merge tree does not equal the exact event head tree" `
        "exact-parent wrong-tree merge"

    $staleMerge = @{} + $commonArguments
    $staleMerge.MergeCommit = $mergeCommit
    Assert-Rejected {
        & $adapter @staleMerge
    } "Fetched pull request merge does not equal" "stale merge identity"

    [void](Invoke-GitTest $seedRoot @(
        "push", "--force", "origin",
        "${mergeCommit}:refs/pull/$pullRequestNumber/merge"
    ))

    $malformedNumber = @{} + $commonArguments
    $malformedNumber.PullRequestNumber = "07"
    Assert-Rejected {
        & $adapter @malformedNumber
    } "Pull request number is malformed" "malformed pull request number"

    $malformedCommit = @{} + $commonArguments
    $malformedCommit.HeadCommit = $headCommit.ToUpperInvariant()
    Assert-Rejected {
        & $adapter @malformedCommit
    } "Head commit is not a lowercase full commit identity" "malformed head identity"

    $badVerifierPin = @{} + $commonArguments
    $badVerifierPin.PinnedVerifierSha256 = "0" * 64
    Assert-Rejected {
        & $adapter @badVerifierPin
    } "Pinned verifier bytes do not equal" "substituted verifier pin"

    Write-Output "External validation authority GitHub adapter self-tests passed."
} finally {
    $rsa.Dispose()
    if (Test-Path -LiteralPath $temp) {
        Get-ChildItem -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $_.Attributes = [IO.FileAttributes]::Normal
                } catch {}
            }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
