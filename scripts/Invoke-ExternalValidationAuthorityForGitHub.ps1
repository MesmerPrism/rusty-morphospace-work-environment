param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$PullRequestNumber,
    [Parameter(Mandatory = $true)][string]$BaseCommit,
    [Parameter(Mandatory = $true)][string]$HeadCommit,
    [string]$MergeCommit = "",
    [Parameter(Mandatory = $true)][string]$PinnedVerifierCommit,
    [Parameter(Mandatory = $true)][string]$PinnedVerifierTree,
    [Parameter(Mandatory = $true)][string]$PinnedVerifierPath,
    [Parameter(Mandatory = $true)][string]$PinnedVerifierSha256,
    [string]$PolicyPath = "config/external-validation-authority.json",
    [string]$RemoteUrl = "",
    [string]$CommentsJsonPath = "",
    [string]$AuthorizationRequestPath = "",
    [switch]$AllowLocalTestRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$GitCommandTimeoutSeconds = 60
$MaximumVerifierBytes = 1048576
$ForbiddenGitEnvironmentVariables = @(
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_SYSTEM",
    "GIT_DIFF_OPTS",
    "GIT_DIR",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    "GIT_GLOB_PATHSPECS",
    "GIT_ICASE_PATHSPECS",
    "GIT_INDEX_FILE",
    "GIT_LITERAL_PATHSPECS",
    "GIT_NAMESPACE",
    "GIT_NOGLOB_PATHSPECS",
    "GIT_OBJECT_DIRECTORY",
    "GIT_QUARANTINE_PATH",
    "GIT_REPLACE_REF_BASE",
    "GIT_SHALLOW_FILE",
    "GIT_WORK_TREE"
)

function Test-ForbiddenGitEnvironmentName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($ForbiddenGitEnvironmentVariables -icontains $Name) {
        return $true
    }
    return (
        $Name.StartsWith("GIT_CONFIG_KEY_", [StringComparison]::OrdinalIgnoreCase) -or
        $Name.StartsWith("GIT_CONFIG_VALUE_", [StringComparison]::OrdinalIgnoreCase)
    )
}

function Assert-CleanGitProcessEnvironment {
    $present = @(
        Get-ChildItem Env: |
            Where-Object { Test-ForbiddenGitEnvironmentName ([string]$_.Name) } |
            ForEach-Object { [string]$_.Name } |
            Sort-Object -CaseSensitive
    )
    if ($present.Count -ne 0) {
        throw (
            "Ambient Git repository/object-store environment is forbidden: " +
            ($present -join ", ")
        )
    }
}

function Assert-FullCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Value -cnotmatch "^(?:[0-9a-f]{40}|[0-9a-f]{64})$") {
        throw "$Label is not a lowercase full commit identity."
    }
}

function Assert-PortableRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (
        [string]::IsNullOrWhiteSpace($Path) -or
        $Path.Length -gt 512 -or
        [IO.Path]::IsPathRooted($Path) -or
        $Path.Contains("\") -or
        $Path.Contains(":") -or
        $Path -match "[\x00-\x1f\x7f]"
    ) {
        throw "$Label is not a portable relative path: $Path"
    }
    $segments = @($Path.Split("/"))
    if (
        $segments.Count -eq 0 -or
        @($segments | Where-Object {
            [string]::IsNullOrEmpty($_) -or $_ -in @(".", "..")
        }).Count -ne 0
    ) {
        throw "$Label contains an empty or traversal segment: $Path"
    }
}

function New-GitStartInfo {
    param([Parameter(Mandatory = $true)][string]$Root)

    $git = @(
        Get-Command git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    )[0].Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $git
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    $start.Environment["GIT_OPTIONAL_LOCKS"] = "0"
    $start.Environment["GIT_LFS_SKIP_SMUDGE"] = "1"
    $start.Environment["GIT_TERMINAL_PROMPT"] = "0"
    $start.Environment["LC_ALL"] = "C"
    $start.Environment["LANG"] = "C"
    foreach ($name in @($start.Environment.Keys)) {
        if (Test-ForbiddenGitEnvironmentName ([string]$name)) {
            [void]$start.Environment.Remove([string]$name)
        }
    }
    $disabledHooks = Join-Path $Root ".git/codex-static-admission-disabled-hooks"
    foreach ($argument in @(
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=$disabledHooks",
        "-c",
        "credential.helper=",
        "-C",
        $Root
    )) {
        [void]$start.ArgumentList.Add($argument)
    }
    return $start
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = $GitCommandTimeoutSeconds
    )

    $start = New-GitStartInfo $Root
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                }
                [void]$process.WaitForExit(5000)
            } catch {}
            throw "Git command timed out after $TimeoutSeconds seconds."
        }
        $result = [pscustomobject]@{
            exit_code = [int]$process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
    if (-not $AllowFailure -and $result.exit_code -ne 0) {
        $detail = ($result.stderr + "`n" + $result.stdout).Trim()
        if ($detail.Length -gt 2048) {
            $detail = $detail.Substring($detail.Length - 2048)
        }
        throw "Git command failed ($($Arguments -join ' ')): $detail"
    }
    return $result
}

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(1, 16777216)][int]$MaximumBytes = $MaximumVerifierBytes
    )

    $start = New-GitStartInfo $Root
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $memory = [IO.MemoryStream]::new()
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [byte[]]$buffer = [byte[]]::new(8192)
        while ($true) {
            $count = $process.StandardOutput.BaseStream.Read(
                $buffer,
                0,
                $buffer.Length
            )
            if ($count -eq 0) {
                break
            }
            if ($memory.Length + $count -gt $MaximumBytes) {
                try {
                    if (-not $process.HasExited) {
                        $process.Kill($true)
                    }
                    [void]$process.WaitForExit(5000)
                } catch {}
                throw "Git byte command exceeded the $MaximumBytes-byte bound."
            }
            $memory.Write($buffer, 0, $count)
        }
        if (-not $process.WaitForExit($GitCommandTimeoutSeconds * 1000)) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                }
                [void]$process.WaitForExit(5000)
            } catch {}
            throw "Git byte command timed out."
        }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Git byte command failed: $($stderr.Trim())"
        }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-GitCommit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $resolved = (
        Invoke-Git $Root @("rev-parse", "--verify", "${Revision}^{commit}")
    ).stdout.Trim()
    if ($resolved -cne $Revision) {
        throw "$Label does not equal its declared commit identity."
    }
    return $resolved
}

function Get-GitTreeEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $line = (Invoke-Git $Root @("ls-tree", $Commit, "--", $Path)).stdout.TrimEnd()
    if ([string]::IsNullOrEmpty($line) -or $line.Contains("`n")) {
        throw "Pinned verifier tree entry is absent or ambiguous."
    }
    if ($line -cnotmatch "^(100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64})`t(.+)$") {
        throw "Pinned verifier tree entry is not a regular file."
    }
    if ($Matches[3] -cne $Path) {
        throw "Pinned verifier tree entry path does not match its declaration."
    }
    return [pscustomobject]@{
        mode = [string]$Matches[1]
        object_id = [string]$Matches[2]
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Get-ExternalOwnerCandidateArtifacts {
    param([string]$Root,[string]$Base,[string]$Head)
    [byte[]]$diff = Invoke-GitBytes $Root @("diff","--name-status","-z","--no-renames",$Base,$Head) 1048576
    $tokens = [Text.Encoding]::UTF8.GetString($diff).Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)
    if (($tokens.Count % 2) -ne 0 -or ($tokens.Count / 2) -gt 512) { throw "External authorization diff is malformed or exceeds its bound." }
    $items = [Collections.Generic.List[object]]::new(); [int64]$total=0
    for($i=0;$i -lt $tokens.Count;$i+=2){
        $path=$tokens[$i+1]; Assert-PortableRelativePath $path "authorization artifact"
        $line=(Invoke-Git $Root @("ls-tree",$Head,"--",$path)).stdout.TrimEnd()
        if([string]::IsNullOrEmpty($line)){ $items.Add([ordered]@{path=$path;state="absent"}); continue }
        if($line -cnotmatch "^(100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64})`t(.+)$" -or $Matches[3] -cne $path){throw "Authorization artifact is not a regular exact path."}
        $size=[int64](Invoke-Git $Root @("cat-file","-s",$Matches[2])).stdout.Trim(); if($size -gt 16777216){throw "Authorization artifact exceeds its size bound."};$total+=$size;if($total -gt 67108864){throw "Authorization artifacts exceed the total hash bound."}
        [byte[]]$bytes=Invoke-GitBytes $Root @("cat-file","blob",$Matches[2]) ([int][Math]::Max(1,$size))
        $items.Add([ordered]@{path=$path;state="present";mode=$Matches[1];size_bytes=$size;sha256=Get-Sha256 $bytes})
    }
    return ,@($items | Sort-Object { [string]$_.path } -CaseSensitive)
}

function Get-PublicIssueComments {
    param(
        [string]$RepositoryName,
        [int]$Number,
        [string]$FixturePath,
        [int]$MaximumComments,
        [int]$MaximumResponseBytes
    )
    Import-Module (Join-Path $PSScriptRoot "lib/ExternalOwnerAuthorization.psm1") -Force
    if($FixturePath){
        if(-not $AllowLocalTestRemote){throw "Comment fixtures are test-only."}
        $raw=[IO.File]::ReadAllBytes((Resolve-Path $FixturePath))
        if($raw.Length -gt $MaximumResponseBytes){throw "Comment response exceeds its size bound."}
        $rawText=[Text.Encoding]::UTF8.GetString($raw)
        $fixtureComments=@(ConvertFrom-ExternalOwnerJsonStrict -Json $rawText)
        if($fixtureComments.Count -gt $MaximumComments){throw "Comment count exceeds the configured bound."}
        return $fixtureComments
    }
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("rusty-morphospace-static-admission/1")
    $deadline=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(20))
    $comments=[Collections.Generic.List[object]]::new()
    [int64]$totalBytes=0
    try{
        for($page=1;;$page++){
            $uri="https://api.github.com/repos/$RepositoryName/issues/$Number/comments?per_page=100&page=$page"
            $response=$client.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$deadline.Token).GetAwaiter().GetResult()
            try{
                if(-not $response.IsSuccessStatusCode){throw "Public comment fetch failed with HTTP $([int]$response.StatusCode)."}
                if($response.Content.Headers.ContentLength -and $totalBytes+$response.Content.Headers.ContentLength -gt $MaximumResponseBytes){throw "Comment response exceeds its size bound."}
                $stream=$response.Content.ReadAsStream($deadline.Token)
                $memory=[IO.MemoryStream]::new()
                try{
                    $buffer=[byte[]]::new(8192)
                    while(($n=$stream.ReadAsync($buffer,0,$buffer.Length,$deadline.Token).GetAwaiter().GetResult())-gt 0){
                        if($totalBytes+$memory.Length+$n -gt $MaximumResponseBytes){throw "Comment response exceeds its size bound."}
                        $memory.Write($buffer,0,$n)
                    }
                    $pageBytes=$memory.ToArray()
                    $totalBytes+=$pageBytes.Length
                    $json=[Text.Encoding]::UTF8.GetString($pageBytes)
                }finally{$memory.Dispose();$stream.Dispose()}
                if(-not $json.TrimStart().StartsWith("[",[StringComparison]::Ordinal)){throw "Comment response must be a JSON array."}
                $pageComments=@(ConvertFrom-ExternalOwnerJsonStrict -Json $json)
                foreach($comment in $pageComments){$comments.Add($comment)}
                if($comments.Count -gt $MaximumComments){throw "Comment count exceeds the configured bound."}
                $links=[Collections.Generic.IEnumerable[string]]$null
                $hasNext=$response.Headers.TryGetValues("Link",[ref]$links)-and @($links|Where-Object{$_ -match 'rel="next"'}).Count -gt 0
                if(-not $hasNext){break}
            }finally{$response.Dispose()}
        }
        return $comments.ToArray()
    }finally{$deadline.Dispose();$client.Dispose();$handler.Dispose()}
}

Assert-CleanGitProcessEnvironment
if ($Repository -cnotmatch "^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$") {
    throw "Repository identity is malformed."
}
if (
    $PullRequestNumber -cnotmatch "^[1-9][0-9]{0,9}$" -or
    [uint64]$PullRequestNumber -gt [uint64][int]::MaxValue
) {
    throw "Pull request number is malformed or outside its bound."
}
Assert-FullCommit $BaseCommit "Base commit"
Assert-FullCommit $HeadCommit "Head commit"
if (-not [string]::IsNullOrEmpty($MergeCommit)) {
    Assert-FullCommit $MergeCommit "Merge commit"
}
Assert-FullCommit $PinnedVerifierCommit "Pinned verifier commit"
Assert-FullCommit $PinnedVerifierTree "Pinned verifier tree"
if ($PinnedVerifierSha256 -cnotmatch "^[0-9a-f]{64}$") {
    throw "Pinned verifier SHA-256 is malformed."
}
Assert-PortableRelativePath $PinnedVerifierPath "pinned verifier path"
Assert-PortableRelativePath $PolicyPath "policy path"

$trusted = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).Path)
$headRef = "refs/codex/static-admission/pr-$PullRequestNumber/head"
$mergeRef = "refs/codex/static-admission/pr-$PullRequestNumber/merge"
$expectedRemote = "https://github.com/$Repository.git"
if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    $RemoteUrl = $expectedRemote
}
if (-not $AllowLocalTestRemote -and $RemoteUrl -cne $expectedRemote) {
    throw "Production static admission requires the exact public HTTPS repository URL."
}
if ($AllowLocalTestRemote -and [string]::IsNullOrWhiteSpace($RemoteUrl)) {
    throw "A local self-test remote must be explicit."
}

$headBeforeFetch = (Invoke-Git $trusted @("rev-parse", "HEAD")).stdout.Trim()
if ($headBeforeFetch -cne $BaseCommit) {
    throw "Trusted checkout HEAD does not equal the event base commit."
}
$dirtyBeforeFetch = (Invoke-Git $trusted @(
    "status", "--porcelain=v1", "-z", "--untracked-files=all"
)).stdout
if ($dirtyBeforeFetch.Length -ne 0) {
    throw "Trusted checkout is dirty before candidate object fetch."
}
$shallow = (Invoke-Git $trusted @("rev-parse", "--is-shallow-repository")).stdout.Trim()
if ($shallow -cne "false") {
    throw "Trusted checkout must be a complete non-shallow repository."
}

[void](Invoke-Git $trusted @(
    "fetch",
    "--force",
    "--no-tags",
    "--no-recurse-submodules",
    "--no-write-fetch-head",
    "--upload-pack=git-upload-pack",
    $RemoteUrl,
    "+refs/pull/$PullRequestNumber/head:$headRef",
    "+refs/pull/$PullRequestNumber/merge:$mergeRef"
))
$fetchedHead = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${headRef}^{commit}")
).stdout.Trim()
$fetchedMerge = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${mergeRef}^{commit}")
).stdout.Trim()
if ($fetchedHead -cne $HeadCommit) {
    throw "Fetched pull request head does not equal the event head commit."
}
if (
    -not [string]::IsNullOrEmpty($MergeCommit) -and
    $fetchedMerge -cne $MergeCommit
) {
    throw "Fetched pull request merge does not equal the event merge commit."
}
$mergeIdentity = (
    Invoke-Git $trusted @("rev-list", "--parents", "-n", "1", $fetchedMerge)
).stdout.Trim().Split(" ", [StringSplitOptions]::RemoveEmptyEntries)
if (
    $mergeIdentity.Count -ne 3 -or
    $mergeIdentity[0] -cne $fetchedMerge -or
    $mergeIdentity[1] -cne $BaseCommit -or
    $mergeIdentity[2] -cne $HeadCommit
) {
    throw "Pull request merge must have the exact ordered event base and head parents."
}
$headTree = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${HeadCommit}^{tree}")
).stdout.Trim()
$mergeTree = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${fetchedMerge}^{tree}")
).stdout.Trim()
if ($mergeTree -cne $headTree) {
    throw "Pull request merge tree does not equal the exact event head tree."
}
$headAlreadyTrusted = Invoke-Git $trusted @(
    "merge-base", "--is-ancestor", $HeadCommit, $BaseCommit
) -AllowFailure
if ($headAlreadyTrusted.exit_code -eq 0) {
    throw "External owner authorization is consumed and inert because the candidate head is already an ancestor of the trusted base."
}

$headAfterFetch = (Invoke-Git $trusted @("rev-parse", "HEAD")).stdout.Trim()
$dirtyAfterFetch = (Invoke-Git $trusted @(
    "status", "--porcelain=v1", "-z", "--untracked-files=all"
)).stdout
if ($headAfterFetch -cne $BaseCommit -or $dirtyAfterFetch.Length -ne 0) {
    throw "Candidate object fetch changed the trusted base checkout."
}

[void](Get-GitCommit $trusted $PinnedVerifierCommit "Pinned verifier commit")
$actualPinnedTree = (
    Invoke-Git $trusted @("rev-parse", "--verify", "${PinnedVerifierCommit}^{tree}")
).stdout.Trim()
if ($actualPinnedTree -cne $PinnedVerifierTree) {
    throw "Pinned verifier tree does not equal its declared tree identity."
}
$pinIsBaseOwned = Invoke-Git $trusted @(
    "merge-base", "--is-ancestor", $PinnedVerifierCommit, $BaseCommit
) -AllowFailure
if ($pinIsBaseOwned.exit_code -ne 0) {
    throw "Pinned verifier commit is not an ancestor of the trusted base."
}
$pinnedEntry = Get-GitTreeEntry $trusted $PinnedVerifierCommit $PinnedVerifierPath
$baseEntry = Get-GitTreeEntry $trusted $BaseCommit $PinnedVerifierPath
if (
    $pinnedEntry.mode -cne $baseEntry.mode -or
    $pinnedEntry.object_id -cne $baseEntry.object_id
) {
    throw "Trusted base verifier entry does not equal the pinned verifier entry."
}
$verifierBytes = Invoke-GitBytes $trusted @(
    "cat-file", "blob", [string]$pinnedEntry.object_id
)
if ((Get-Sha256 $verifierBytes) -cne $PinnedVerifierSha256) {
    throw "Pinned verifier bytes do not equal the declared SHA-256."
}

$verifierFullPath = [IO.Path]::GetFullPath((Join-Path $trusted $PinnedVerifierPath))
$trustedPrefix = $trusted.TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
if (-not $verifierFullPath.StartsWith($trustedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Pinned verifier entrypoint escapes the trusted checkout."
}
$verifierItem = Get-Item -LiteralPath $verifierFullPath -Force
if (
    $verifierItem.PSIsContainer -or
    ($verifierItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
) {
    throw "Pinned verifier entrypoint is not a regular checked-out file."
}

$externalOutcome=$false
try {
    $assessmentJson = & $verifierFullPath -RepositoryRoot $trusted -PolicyPath $PolicyPath -Repository $Repository -BaseCommit $BaseCommit -CandidateCommit $HeadCommit -Json
} catch {
    if ($_.Exception.Message -cne "Protected changes do not match an exact base-approved change set.") { throw }
    $externalOutcome=$true
}
if($externalOutcome){
    $policy=Get-Content -Raw (Join-Path $trusted $PolicyPath)|ConvertFrom-Json -Depth 30
    $ownerPolicyPath=Join-Path $trusted "config/external-owner-authorization.json"
    $artifacts=Get-ExternalOwnerCandidateArtifacts $trusted $BaseCommit $HeadCommit
    $protectedPaths=@($artifacts|ForEach-Object{$path=[string]$_.path;$matched=@($policy.mandatory_protected_paths)-ccontains $path;if(-not $matched){foreach($rule in @($policy.protected_rules)){if(([string]$rule.match -ceq "exact" -and $path -ceq [string]$rule.path)-or([string]$rule.match -ceq "prefix" -and $path.StartsWith([string]$rule.path,[StringComparison]::Ordinal))){$matched=$true;break}}};if($matched){$path}})
    $baseTree=(Invoke-Git $trusted @("rev-parse","${BaseCommit}^{tree}")).stdout.Trim()
    Import-Module (Join-Path $trusted "scripts/lib/ExternalOwnerAuthorization.psm1") -Force
    $ownerPolicy=Read-ExternalOwnerAuthorizationPolicy -Path $ownerPolicyPath -SchemaPath (Join-Path $trusted "schemas/external-owner-authorization-policy-v1.schema.json")
    $requestAssessment=[ordered]@{schema="rusty.morphospace.workflow.external_validation_authority_assessment.v1";policy_id=[string]$policy.policy_id;policy_sha256=Get-Sha256 ([IO.File]::ReadAllBytes((Join-Path $trusted $PolicyPath)));repository=$Repository;base=[ordered]@{commit=$BaseCommit;tree=$baseTree};candidate=[ordered]@{commit=$HeadCommit;tree=$headTree};changed_paths=@($artifacts|ForEach-Object{$_.path});protected_paths=$protectedPaths;decision="external-owner-authorization";approval_id="external-owner-authorization-required";candidate_code_executed=$false;execution_attested=$false;publication_authority=$false;limitations=@("Static admission only; no candidate code was executed.","Execution, tests, acceptance, and publication remain separately authorized.","External owner authorization permits only this base verifier assessment.")}
    $request=New-ExternalOwnerAuthorizationRequest ([string]$ownerPolicy.issuer_id) $Repository ([int]$PullRequestNumber) ([ordered]@{commit=$BaseCommit;tree=$baseTree}) ([ordered]@{commit=$HeadCommit;tree=$headTree}) $artifacts $requestAssessment
    $requestText=$request|ConvertTo-Json -Depth 30
    if(-not(Test-Json -Json ($requestAssessment|ConvertTo-Json -Depth 30) -SchemaFile (Join-Path $trusted "schemas/external-validation-authority-assessment-v1.schema.json") -ErrorAction Stop)){throw "Request assessment failed its schema."}
    if(-not(Test-Json -Json $requestText -SchemaFile (Join-Path $trusted "schemas/external-owner-authorization-request-v1.schema.json") -ErrorAction Stop)){throw "External owner authorization request failed its schema."}
    $comments=@(Get-PublicIssueComments $Repository ([int]$PullRequestNumber) $CommentsJsonPath ([int]$ownerPolicy.maximum_comments) ([int]$ownerPolicy.maximum_response_bytes))
    $markerComments=@($comments|Where-Object{[string]$_.user.login -ceq [string]$ownerPolicy.owner_login -and [regex]::Matches([string]$_.body,"(?m)^$([regex]::Escape([string]$ownerPolicy.comment_marker))$").Count -gt 0})
    $emitRequest={if($AuthorizationRequestPath){if(-not $AllowLocalTestRemote){throw "Authorization request fixture output is test-only."};[IO.File]::WriteAllText($AuthorizationRequestPath,$requestText,[Text.UTF8Encoding]::new($false))};Write-Output $requestText;throw "External owner authorization is required; the canonical request was emitted."}
    if($markerComments.Count -eq 0){& $emitRequest}
    $validAuthorizations=[Collections.Generic.List[object]]::new()
    foreach($markerComment in $markerComments){
        try{
            $payloadText=([string]$markerComment.body -split "\r?\n",2)[1]
            $payloadDoc=ConvertFrom-ExternalOwnerJsonStrict -Json $payloadText
            $expected=New-ExternalOwnerAuthorizationPayload $request ([string]$payloadDoc.payload.authorization_id) ([string]$payloadDoc.payload.issued_at) ([string]$payloadDoc.payload.expires_at)
            $verified=Test-ExternalOwnerAuthorizationComments @($markerComment) $expected $ownerPolicy ([datetimeoffset]::UtcNow) (Join-Path $trusted "schemas/external-owner-authorization-v1.schema.json")
            $validAuthorizations.Add($verified)
        }catch{continue}
    }
    if($validAuthorizations.Count -eq 0){& $emitRequest}
    if($validAuthorizations.Count -ne 1){throw "Exactly one current exact-evidence owner authorization is required."}
    $assessmentJson=$requestAssessment|ConvertTo-Json -Depth 30
}
$assessmentText = @($assessmentJson) -join "`n"
$assessment = $assessmentText | ConvertFrom-Json -Depth 30
$assessmentSchema = Join-Path $trusted "schemas/external-validation-authority-assessment-v1.schema.json"
if (-not (Test-Json -Json $assessmentText -SchemaFile $assessmentSchema -ErrorAction Stop)) {
    throw "Base-owned verifier returned an assessment outside the schema."
}
if (
    [string]$assessment.repository -cne $Repository -or
    [string]$assessment.base.commit -cne $BaseCommit -or
    [string]$assessment.candidate.commit -cne $HeadCommit -or
    [bool]$assessment.candidate_code_executed -ne $false -or
    [bool]$assessment.execution_attested -ne $false -or
    [bool]$assessment.publication_authority -ne $false
) {
    throw "Base-owned verifier returned an inconsistent static assessment."
}

Write-Output $assessmentText
