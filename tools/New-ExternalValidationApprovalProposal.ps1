[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$')][string]$Repository,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,127}$')][string]$ApprovalId,
    [Parameter(Mandatory)][ValidatePattern('^(?:[0-9a-f]{40}|[0-9a-f]{64})$')][string]$BaseCommit,
    [Parameter(Mandatory)][ValidatePattern('^(?:[0-9a-f]{40}|[0-9a-f]{64})$')][string]$CandidateCommit,
    [ValidatePattern('^(?:[0-9a-f]{40}|[0-9a-f]{64})$')][string]$RequiredAncestor = "",
    [string]$OutPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$GitCommandTimeoutSeconds = 30
$MaximumChangedPaths = 512
$MaximumTreeBytes = 16777216
$MaximumArtifactBytes = [int64]16777216
$MaximumTotalCandidateBlobBytes = [int64]67108864
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

if ($ApprovalId -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') {
    throw "Approval ID is malformed or not lowercase canonical form."
}
foreach ($commitInput in @($BaseCommit, $CandidateCommit) + @($RequiredAncestor | Where-Object { $_ })) {
    if ($commitInput -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        throw "Commit identity is malformed or not lowercase canonical form."
    }
}

function Test-ForbiddenGitEnvironmentName {
    param([Parameter(Mandatory)][string]$Name)

    if ($ForbiddenGitEnvironmentVariables -icontains $Name) { return $true }
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
        throw "Ambient Git repository/object-store environment is forbidden: $($present -join ', ')"
    }
}

function New-GitStartInfo {
    param([Parameter(Mandatory)][string]$Root)

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
    $start.Environment["LC_ALL"] = "C"
    $start.Environment["LANG"] = "C"
    foreach ($name in @($start.Environment.Keys)) {
        if (Test-ForbiddenGitEnvironmentName ([string]$name)) {
            [void]$start.Environment.Remove([string]$name)
        }
    }
    foreach ($argument in @("--no-optional-locks", "-c", "core.fsmonitor=false", "-C", $Root)) {
        [void]$start.ArgumentList.Add($argument)
    }
    return $start
}

function Stop-GitProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$Reason
    )

    try {
        if (-not $Process.HasExited) { $Process.Kill($true) }
        if (-not $Process.WaitForExit(5000)) {
            throw "process did not exit within the five-second cleanup bound"
        }
    } catch {
        throw "$Reason; Git process cleanup failed: $($_.Exception.Message)"
    }
    throw $Reason
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $start = New-GitStartInfo $Root
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($GitCommandTimeoutSeconds * 1000)) {
            Stop-GitProcess $process "Git command timed out after $GitCommandTimeoutSeconds seconds"
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
        if ($detail.Length -gt 2048) { $detail = $detail.Substring($detail.Length - 2048) }
        throw "Git command failed ($($Arguments -join ' ')): $detail"
    }
    return $result
}

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 67108864)][int]$MaximumBytes = 1048576
    )

    $start = New-GitStartInfo $Root
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($GitCommandTimeoutSeconds)
    $memory = [IO.MemoryStream]::new()
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [byte[]]$buffer = [byte[]]::new(8192)
        while ($true) {
            $remaining = $deadline - [DateTimeOffset]::UtcNow
            if ($remaining.TotalMilliseconds -le 0) {
                Stop-GitProcess $process "Git byte command timed out"
            }
            $readTask = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait([int][Math]::Ceiling($remaining.TotalMilliseconds))) {
                Stop-GitProcess $process "Git byte command timed out"
            }
            $count = $readTask.GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            if ($memory.Length + $count -gt $MaximumBytes) {
                Stop-GitProcess $process "Git byte command exceeded its $MaximumBytes-byte output bound"
            }
            $memory.Write($buffer, 0, $count)
        }
        $remaining = $deadline - [DateTimeOffset]::UtcNow
        if (
            $remaining.TotalMilliseconds -le 0 -or
            -not $process.WaitForExit([int][Math]::Ceiling($remaining.TotalMilliseconds))
        ) {
            Stop-GitProcess $process "Git byte command timed out"
        }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = $stderr.Trim()
            if ($detail.Length -gt 2048) { $detail = $detail.Substring($detail.Length - 2048) }
            throw "Git byte command failed: $detail"
        }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-OrdinalSorted {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Values)

    [string[]]$copy = @($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return ,$copy
}

function Assert-PortableRelativePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)

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
        @($segments | Where-Object { [string]::IsNullOrEmpty($_) -or $_ -in @(".", "..") }).Count -ne 0
    ) {
        throw "$Label contains an empty or traversal segment: $Path"
    }
}

function Assert-GitInspectionEnvironment {
    param([Parameter(Mandatory)][string]$Root)

    $replaceRefs = (Invoke-GitText $Root @("for-each-ref", "--format=%(refname)", "refs/replace")).stdout.Trim()
    if ($replaceRefs.Length -ne 0) { throw "Trusted Git inspection repository contains replacement refs." }
    $shallow = (Invoke-GitText $Root @("rev-parse", "--is-shallow-repository")).stdout.Trim()
    if ($shallow -cne "false") { throw "Trusted Git inspection repository must be a complete non-shallow clone." }
    $commonDirText = (Invoke-GitText $Root @("rev-parse", "--path-format=absolute", "--git-common-dir")).stdout.Trim()
    $commonDir = [IO.Path]::GetFullPath($commonDirText)
    foreach ($metadataPath in @((Join-Path $commonDir "objects/info/alternates"), (Join-Path $commonDir "info/grafts"))) {
        if (Test-Path -LiteralPath $metadataPath) {
            throw "Trusted Git inspection repository contains external object metadata: $metadataPath"
        }
    }
}

function Get-GitCommitIdentity {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$Label,
        [switch]$RequireHead
    )

    $commit = (Invoke-GitText $Root @("rev-parse", "--verify", "$ExpectedCommit`^{commit}")).stdout.Trim()
    $tree = (Invoke-GitText $Root @("rev-parse", "--verify", "$ExpectedCommit`^{tree}")).stdout.Trim()
    if ($commit -cne $ExpectedCommit) { throw "$Label does not equal the declared commit." }
    if ($RequireHead) {
        $head = (Invoke-GitText $Root @("rev-parse", "HEAD")).stdout.Trim()
        if ($head -cne $ExpectedCommit) { throw "$Label checkout HEAD does not equal the declared commit." }
        [byte[]]$dirty = Invoke-GitBytes $Root @("status", "--porcelain=v1", "-z", "--untracked-files=all")
        if ($dirty.Length -ne 0) { throw "$Label checkout is dirty." }
    }
    return [pscustomobject][ordered]@{ commit = $commit; tree = $tree }
}

function Get-ChangedPaths {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Candidate)

    [byte[]]$bytes = Invoke-GitBytes $Root @(
        "diff", "--name-status", "-z", "--no-renames", "--no-ext-diff", $Base, $Candidate, "--"
    ) -MaximumBytes 1048576
    $tokens = [Collections.Generic.List[byte[]]]::new()
    $start = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -ne 0) { continue }
        $length = $index - $start
        [byte[]]$token = [byte[]]::new($length)
        if ($length -gt 0) { [Array]::Copy($bytes, $start, $token, 0, $length) }
        $tokens.Add($token)
        $start = $index + 1
        if ($tokens.Count -gt ($MaximumChangedPaths * 2)) {
            throw "Candidate diff exceeds the $MaximumChangedPaths-path proposal bound."
        }
    }
    if ($start -ne $bytes.Length -or ($tokens.Count % 2) -ne 0) {
        throw "Git changed-path output is malformed."
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $paths = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $tokens.Count; $index += 2) {
        try {
            $status = $utf8.GetString($tokens[$index])
            $path = $utf8.GetString($tokens[$index + 1])
        } catch {
            throw "Git changed-path output contains non-canonical UTF-8."
        }
        if ($status -cnotmatch "^[A-Z][0-9]*$") { throw "Git changed-path status is unsupported: $status" }
        Assert-PortableRelativePath $path "changed path"
        $paths.Add($path)
    }
    if ($paths.Count -eq 0) { throw "Candidate has no changed paths relative to the declared base." }
    [string[]]$sorted = Get-OrdinalSorted @($paths)
    for ($index = 1; $index -lt $sorted.Count; $index++) {
        if ($sorted[$index - 1] -ceq $sorted[$index]) { throw "Candidate diff contains a duplicate path: $($sorted[$index])" }
    }
    return ,$sorted
}

function Get-CandidateTreeEntries {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string[]]$ChangedPaths
    )

    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $wanted = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($path in $ChangedPaths) {
        $wanted.Add([Convert]::ToBase64String($utf8.GetBytes($path)), $path)
    }
    [byte[]]$bytes = Invoke-GitBytes $Root @("ls-tree", "-r", "-z", "--full-tree", $Candidate) -MaximumBytes $MaximumTreeBytes
    $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $recordStart = 0
    for ($index = 0; $index -le $bytes.Length; $index++) {
        if ($index -lt $bytes.Length -and $bytes[$index] -ne 0) { continue }
        if ($index -eq $bytes.Length -and $recordStart -ne $bytes.Length) {
            throw "Git tree output lacks a terminal NUL."
        }
        $recordLength = $index - $recordStart
        if ($recordLength -gt 0) {
            $tab = -1
            for ($offset = 0; $offset -lt $recordLength; $offset++) {
                if ($bytes[$recordStart + $offset] -eq 9) { $tab = $offset; break }
            }
            if ($tab -le 0) { throw "Git tree entry is malformed." }
            [byte[]]$pathBytes = [byte[]]::new($recordLength - $tab - 1)
            if ($pathBytes.Length -gt 0) {
                [Array]::Copy($bytes, $recordStart + $tab + 1, $pathBytes, 0, $pathBytes.Length)
            }
            $key = [Convert]::ToBase64String($pathBytes)
            if ($wanted.ContainsKey($key)) {
                $metadata = [Text.Encoding]::ASCII.GetString($bytes, $recordStart, $tab).Split(" ")
                if ($metadata.Count -ne 3) { throw "Git tree metadata is malformed." }
                $path = $wanted[$key]
                if ($entries.ContainsKey($path)) { throw "Candidate tree path is not unique: $path" }
                $entries.Add($path, [pscustomobject]@{
                    mode = $metadata[0]
                    type = $metadata[1]
                    object_id = $metadata[2]
                })
            }
        }
        $recordStart = $index + 1
    }
    return $entries
}

function Read-BoundedStreamByte {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][DateTimeOffset]$Deadline,
        [Parameter(Mandatory)][Diagnostics.Process]$Process
    )

    [byte[]]$single = [byte[]]::new(1)
    $remaining = $Deadline - [DateTimeOffset]::UtcNow
    if ($remaining.TotalMilliseconds -le 0) { Stop-GitProcess $Process "Git cat-file batch timed out" }
    $task = $Stream.ReadAsync($single, 0, 1)
    if (-not $task.Wait([int][Math]::Ceiling($remaining.TotalMilliseconds))) {
        Stop-GitProcess $Process "Git cat-file batch timed out"
    }
    $count = $task.GetAwaiter().GetResult()
    if ($count -ne 1) { throw "Git cat-file batch ended unexpectedly." }
    return [byte]$single[0]
}

function Read-BoundedAsciiLine {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][DateTimeOffset]$Deadline,
        [Parameter(Mandatory)][Diagnostics.Process]$Process
    )

    $bytes = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $value = Read-BoundedStreamByte $Stream $Deadline $Process
        if ($value -eq 10) { break }
        if ($value -gt 127 -or $value -eq 13) { throw "Git cat-file header is not canonical ASCII." }
        $bytes.Add($value)
        if ($bytes.Count -gt 256) { throw "Git cat-file header exceeds its bound." }
    }
    return [Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Get-GitBlobEvidenceBatch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ObjectIds
    )

    [string[]]$sortedIds = Get-OrdinalSorted @($ObjectIds | Select-Object -Unique)
    $evidence = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($sortedIds.Count -eq 0) { return $evidence }
    $start = New-GitStartInfo $Root
    $start.RedirectStandardInput = $true
    foreach ($argument in @("cat-file", "--batch")) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($GitCommandTimeoutSeconds)
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $input = ($sortedIds -join "`n") + "`n"
        $process.StandardInput.Write($input)
        $process.StandardInput.Close()
        [int64]$totalBytes = 0
        [byte[]]$buffer = [byte[]]::new(8192)
        foreach ($objectId in $sortedIds) {
            $header = Read-BoundedAsciiLine $process.StandardOutput.BaseStream $deadline $process
            $fields = $header.Split(" ")
            [int64]$size = 0
            if (
                $fields.Count -ne 3 -or
                $fields[0] -cne $objectId -or
                $fields[1] -cne "blob" -or
                -not [int64]::TryParse($fields[2], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$size) -or
                $size -lt 0 -or
                $size -gt $MaximumArtifactBytes
            ) {
                throw "Candidate Git object is missing, non-blob, or exceeds the per-artifact bound: $objectId"
            }
            $totalBytes += $size
            if ($totalBytes -gt $MaximumTotalCandidateBlobBytes) {
                throw "Candidate blobs exceed the $MaximumTotalCandidateBlobBytes-byte total hashing bound."
            }
            $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                [int64]$remainingBytes = $size
                while ($remainingBytes -gt 0) {
                    $remainingTime = $deadline - [DateTimeOffset]::UtcNow
                    if ($remainingTime.TotalMilliseconds -le 0) { Stop-GitProcess $process "Git cat-file batch timed out" }
                    $requested = [int][Math]::Min($buffer.Length, $remainingBytes)
                    $task = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $requested)
                    if (-not $task.Wait([int][Math]::Ceiling($remainingTime.TotalMilliseconds))) {
                        Stop-GitProcess $process "Git cat-file batch timed out"
                    }
                    $count = $task.GetAwaiter().GetResult()
                    if ($count -le 0) { throw "Git cat-file blob ended unexpectedly: $objectId" }
                    $hash.AppendData($buffer, 0, $count)
                    $remainingBytes -= $count
                }
                $terminator = Read-BoundedStreamByte $process.StandardOutput.BaseStream $deadline $process
                if ($terminator -ne 10) { throw "Git cat-file blob lacks its terminal newline: $objectId" }
                $evidence.Add($objectId, [pscustomobject]@{
                    size_bytes = $size
                    sha256 = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
                })
            } finally {
                $hash.Dispose()
            }
        }
        $remainingTime = $deadline - [DateTimeOffset]::UtcNow
        if (
            $remainingTime.TotalMilliseconds -le 0 -or
            -not $process.WaitForExit([int][Math]::Ceiling($remainingTime.TotalMilliseconds))
        ) {
            Stop-GitProcess $process "Git cat-file batch timed out"
        }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = $stderr.Trim()
            if ($detail.Length -gt 2048) { $detail = $detail.Substring($detail.Length - 2048) }
            throw "Git cat-file batch failed: $detail"
        }
    } catch {
        if (-not $process.HasExited) {
            try { $process.Kill($true); [void]$process.WaitForExit(5000) } catch { }
        }
        throw
    } finally {
        $process.Dispose()
    }
    return $evidence
}

function Test-PathInside {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    return (
        $pathFull.Equals($rootFull, $comparison) -or
        $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)
    )
}

function Assert-NoReparseOutputPath {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Path)

    foreach ($candidate in @($Parent, $Path)) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $item = Get-Item -LiteralPath $candidate -Force
        if (
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (
                $item.PSObject.Properties.Name -contains "LinkType" -and
                -not [string]::IsNullOrEmpty([string]$item.LinkType)
            )
        ) {
            throw "Proposal output path contains a symbolic link or reparse point: $candidate"
        }
    }
}

$trusted = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).Path)
Assert-CleanGitProcessEnvironment
Assert-GitInspectionEnvironment $trusted
$baseIdentity = Get-GitCommitIdentity $trusted $BaseCommit "trusted base" -RequireHead
$candidateIdentity = Get-GitCommitIdentity $trusted $CandidateCommit "candidate"

$baseInCandidate = Invoke-GitText $trusted @("merge-base", "--is-ancestor", $BaseCommit, $CandidateCommit) -AllowFailure
if ($baseInCandidate.exit_code -eq 1) { throw "Trusted base is not an ancestor of the candidate." }
if ($baseInCandidate.exit_code -ne 0) { throw "Trusted-base ancestry could not be evaluated." }

$required = if ($RequiredAncestor) { $RequiredAncestor } else { $CandidateCommit }
$requiredIdentity = Get-GitCommitIdentity $trusted $required "required ancestor"
$consumed = Invoke-GitText $trusted @("merge-base", "--is-ancestor", $required, $BaseCommit) -AllowFailure
if ($consumed.exit_code -eq 0) { throw "Required ancestor is already consumed by the trusted base." }
if ($consumed.exit_code -ne 1) { throw "Required-ancestor consumption could not be evaluated." }
$requiredInCandidate = Invoke-GitText $trusted @("merge-base", "--is-ancestor", $required, $CandidateCommit) -AllowFailure
if ($requiredInCandidate.exit_code -eq 1) { throw "Required ancestor is not an ancestor of the candidate." }
if ($requiredInCandidate.exit_code -ne 0) { throw "Required-ancestor candidate ancestry could not be evaluated." }

[string[]]$changedPaths = Get-ChangedPaths $trusted $BaseCommit $CandidateCommit
$entries = Get-CandidateTreeEntries $trusted $CandidateCommit $changedPaths
[string[]]$objectIds = @(
    foreach ($path in $changedPaths) {
        if ($entries.ContainsKey($path)) {
            $entry = $entries[$path]
            if (
                [string]$entry.mode -notin @("100644", "100755") -or
                [string]$entry.type -cne "blob" -or
                [string]$entry.object_id -cnotmatch "^(?:[0-9a-f]{40}|[0-9a-f]{64})$"
            ) {
                throw "Candidate path is not a regular tracked file supported by the approval policy: $path"
            }
            [string]$entry.object_id
        }
    }
)
$blobEvidence = Get-GitBlobEvidenceBatch $trusted $objectIds
$artifacts = [Collections.Generic.List[object]]::new()
foreach ($path in $changedPaths) {
    if (-not $entries.ContainsKey($path)) {
        $artifacts.Add([pscustomobject][ordered]@{ path = $path; state = "absent" })
        continue
    }
    $entry = $entries[$path]
    $evidence = $blobEvidence[[string]$entry.object_id]
    $artifacts.Add([pscustomobject][ordered]@{
        path = $path
        state = "present"
        mode = [string]$entry.mode
        size_bytes = [int64]$evidence.size_bytes
        sha256 = [string]$evidence.sha256
    })
}

$proposal = [pscustomobject][ordered]@{
    schema = "rusty.morphospace.workflow.external_validation_approval_proposal.v1"
    proposal_status = "review-required"
    repository = $Repository
    base = $baseIdentity
    candidate = $candidateIdentity
    required_ancestor = $requiredIdentity
    evidence_source = "canonical-git-objects"
    candidate_checkout_performed = $false
    candidate_code_executed = $false
    working_tree_file_content_read = $false
    git_mutation_performed = $false
    remote_mutation_performed = $false
    approval_authority = $false
    execution_attested = $false
    publication_authority = $false
    approval_candidate = [pscustomobject][ordered]@{
        approval_id = $ApprovalId
        required_ancestor = $required
        changed_paths = $changedPaths
        artifacts = $artifacts.ToArray()
    }
    review_requirements = @(
        "Review the exact intent and every changed path before granting approval.",
        "Install the reviewed candidate into policy from a separate trusted-base change.",
        "Add status=approved only in that separately reviewed policy change.",
        "Run base-owned static admission and independent dynamic validation afterward."
    )
    limitations = @(
        "This proposal grants no approval, execution, merge, release, or publication authority.",
        "It does not classify protected paths or execute candidate code.",
        "It is exact only for the recorded base, candidate, required ancestor, and Git blob evidence."
    )
}
$json = ($proposal | ConvertTo-Json -Depth 30).Replace("`r`n", "`n") + "`n"

if ($OutPath) {
    $fullOutPath = [IO.Path]::GetFullPath($OutPath)
    if (Test-PathInside $trusted $fullOutPath) {
        throw "Proposal output must remain outside the trusted Git checkout."
    }
    $parent = Split-Path -Parent $fullOutPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Proposal output parent does not exist: $parent"
    }
    Assert-NoReparseOutputPath $parent $fullOutPath
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new(
        $fullOutPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

Write-Output $json
