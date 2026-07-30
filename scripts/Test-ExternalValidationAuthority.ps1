param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$PolicyPath,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$BaseCommit,
    [Parameter(Mandatory = $true)][string]$CandidateCommit,
    [string]$OutPath = "",
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$MaximumArtifactBytes = [int64]16777216
$MaximumTotalCandidateBlobBytes = [int64]67108864
$GitCommandTimeoutSeconds = 30
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
        $Name.StartsWith(
            "GIT_CONFIG_KEY_",
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $Name.StartsWith(
            "GIT_CONFIG_VALUE_",
            [StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Assert-CleanGitProcessEnvironment {
    $present = @(
        Get-ChildItem Env: |
            Where-Object {
                Test-ForbiddenGitEnvironmentName ([string]$_.Name)
            } |
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

function Assert-StrictJson {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if (-not ("RustyMorphospace.StrictJson" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text.Json;

namespace RustyMorphospace
{
    public static class StrictJson
    {
        public static void AssertNoDuplicateProperties(byte[] bytes)
        {
            Utf8JsonReader reader = new Utf8JsonReader(
                bytes,
                new JsonReaderOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 64
                });
            Stack<HashSet<string>> objects = new Stack<HashSet<string>>();
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    objects.Push(new HashSet<string>(StringComparer.OrdinalIgnoreCase));
                }
                else if (reader.TokenType == JsonTokenType.EndObject)
                {
                    if (objects.Count == 0) throw new JsonException("Unbalanced JSON object.");
                    objects.Pop();
                }
                else if (reader.TokenType == JsonTokenType.PropertyName)
                {
                    if (objects.Count == 0) throw new JsonException("JSON property is outside an object.");
                    string name = reader.GetString();
                    if (!objects.Peek().Add(name))
                        throw new JsonException("Duplicate or case-colliding JSON property: " + name);
                }
            }
            if (objects.Count != 0) throw new JsonException("Unbalanced JSON object.");
        }
    }
}
'@
    }
    [RustyMorphospace.StrictJson]::AssertNoDuplicateProperties($Bytes)
}

function Get-BytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (
            [BitConverter]::ToString($sha.ComputeHash($Bytes))
        ).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-OrdinalSequenceEqual {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Left,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if (-not [string]::Equals(
            $Left[$index],
            $Right[$index],
            [StringComparison]::Ordinal
        )) {
            return $false
        }
    }
    return $true
}

function Get-OrdinalSorted {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Values
    )

    [string[]]$copy = @($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return ,$copy
}

function Assert-SortedUnique {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Values,
        [Parameter(Mandatory = $true)][string]$Label
    )

    [string[]]$sorted = Get-OrdinalSorted $Values
    if (-not (Test-OrdinalSequenceEqual $Values $sorted)) {
        throw "$Label must be ordinally sorted."
    }
    for ($index = 1; $index -lt $Values.Count; $index++) {
        if ([string]::Equals(
            $Values[$index - 1],
            $Values[$index],
            [StringComparison]::Ordinal
        )) {
            throw "$Label contains a duplicate: $($Values[$index])"
        }
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

function Assert-PortableRulePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Match
    )

    if ($Match -ceq "exact") {
        Assert-PortableRelativePath $Path "exact protected rule path"
        return
    }
    if ($Match -cne "prefix") {
        throw "Protected rule match is unsupported: $Match"
    }
    if (-not $Path.EndsWith("/", [StringComparison]::Ordinal)) {
        throw "Protected prefix rule must end with '/': $Path"
    }
    $withoutSlash = $Path.Substring(0, $Path.Length - 1)
    Assert-PortableRelativePath $withoutSlash "protected prefix rule path"
}

function Assert-NoLinkAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $candidate = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not (
        $candidate.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    )) {
        throw "Path escapes the declared root: $Path"
    }

    $current = $candidate
    while (
        $current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $current.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    ) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (
                    $item.PSObject.Properties.Name -contains "LinkType" -and
                    -not [string]::IsNullOrEmpty([string]$item.LinkType)
                )
            ) {
                throw "Path contains a symbolic link or reparse point: $current"
            }
        }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
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
    $start.Environment["LC_ALL"] = "C"
    $start.Environment["LANG"] = "C"
    foreach ($name in @($start.Environment.Keys)) {
        if (Test-ForbiddenGitEnvironmentName ([string]$name)) {
            [void]$start.Environment.Remove([string]$name)
        }
    }
    foreach ($argument in @(
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        "-C",
        $Root
    )) {
        [void]$start.ArgumentList.Add($argument)
    }
    return $start
}

function Stop-GitProcessAfterTimeout {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
        }
        if (-not $Process.WaitForExit(5000)) {
            throw "process did not exit within the five-second cleanup bound"
        }
    } catch {
        throw "$Label timed out and its process could not be reaped: $($_.Exception.Message)"
    }
    throw "$Label timed out."
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
            Stop-GitProcessAfterTimeout $process (
                "Git command after $TimeoutSeconds seconds"
            )
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $result = [pscustomobject]@{
            exit_code = [int]$process.ExitCode
            stdout = $stdout
            stderr = $stderr
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
        [ValidateRange(1, 16777216)][int]$MaximumBytes = 1048576,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $start = New-GitStartInfo $Root
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $memory = [IO.MemoryStream]::new()
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [byte[]]$buffer = [byte[]]::new(8192)
        while ($true) {
            $remaining = $deadline - [DateTimeOffset]::UtcNow
            if ($remaining.TotalMilliseconds -le 0) {
                Stop-GitProcessAfterTimeout $process "Git byte command"
            }
            $readTask = $process.StandardOutput.BaseStream.ReadAsync(
                $buffer,
                0,
                $buffer.Length
            )
            if (-not $readTask.Wait([int][Math]::Ceiling($remaining.TotalMilliseconds))) {
                Stop-GitProcessAfterTimeout $process "Git byte command"
            }
            $count = $readTask.GetAwaiter().GetResult()
            if ($count -eq 0) {
                break
            }
            if ($memory.Length + $count -gt $MaximumBytes) {
                try {
                    if (-not $process.HasExited) {
                        $process.Kill($true)
                    }
                    if (-not $process.WaitForExit(5000)) {
                        throw "process did not exit within the cleanup bound"
                    }
                } catch {
                    throw (
                        "Git byte command exceeded its output bound and cleanup failed: " +
                        $_.Exception.Message
                    )
                }
                throw "Git byte command exceeded the $MaximumBytes-byte output bound."
            }
            $memory.Write($buffer, 0, $count)
        }
        $remaining = $deadline - [DateTimeOffset]::UtcNow
        if (
            $remaining.TotalMilliseconds -le 0 -or
            -not $process.WaitForExit([int][Math]::Ceiling($remaining.TotalMilliseconds))
        ) {
            Stop-GitProcessAfterTimeout $process "Git byte command"
        }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = $stderr.Trim()
            if ($detail.Length -gt 2048) {
                $detail = $detail.Substring($detail.Length - 2048)
            }
            throw "Git byte command failed: $detail"
        }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Assert-GitInspectionEnvironment {
    param([Parameter(Mandatory = $true)][string]$Root)

    $replaceRefs = (
        Invoke-Git $Root @("for-each-ref", "--format=%(refname)", "refs/replace")
    ).stdout.Trim()
    if ($replaceRefs.Length -ne 0) {
        throw "Trusted Git inspection repository contains replacement refs."
    }

    $shallow = (
        Invoke-Git $Root @("rev-parse", "--is-shallow-repository")
    ).stdout.Trim()
    if ($shallow -cne "false") {
        throw "Trusted Git inspection repository must be a complete non-shallow clone."
    }

    $commonDirText = (
        Invoke-Git $Root @("rev-parse", "--path-format=absolute", "--git-common-dir")
    ).stdout.Trim()
    $commonDir = [IO.Path]::GetFullPath($commonDirText)
    foreach ($metadataPath in @(
        (Join-Path $commonDir "objects/info/alternates"),
        (Join-Path $commonDir "info/grafts")
    )) {
        if (Test-Path -LiteralPath $metadataPath) {
            throw "Trusted Git inspection repository contains external object metadata: $metadataPath"
        }
    }
}

function Get-GitCommitIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$RequireHead
    )

    if ($ExpectedCommit -cnotmatch "^(?:[0-9a-f]{40}|[0-9a-f]{64})$") {
        throw "$Label commit is malformed."
    }
    $commit = (
        Invoke-Git $Root @("rev-parse", "--verify", "$ExpectedCommit`^{commit}")
    ).stdout.Trim()
    $tree = (
        Invoke-Git $Root @("rev-parse", "--verify", "$ExpectedCommit`^{tree}")
    ).stdout.Trim()
    if ($commit -cne $ExpectedCommit) {
        throw "$Label checkout does not equal the declared commit."
    }
    if ($RequireHead) {
        $head = (Invoke-Git $Root @("rev-parse", "HEAD")).stdout.Trim()
        if ($head -cne $ExpectedCommit) {
            throw "$Label checkout HEAD does not equal the declared commit."
        }
        $dirty = (Invoke-Git $Root @(
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all"
        )).stdout
        if ($dirty.Length -ne 0) {
            throw "$Label checkout is dirty."
        }
    }
    return [pscustomobject][ordered]@{
        commit = $commit
        tree = $tree
    }
}

function Get-GitTreeEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Assert-PortableRelativePath $Path "tree path"
    $result = Invoke-Git $Root @("ls-tree", "-z", $Commit, "--", $Path)
    if ($result.stdout.Length -eq 0) {
        return $null
    }
    [string[]]$records = @($result.stdout.Split(
        [char]0,
        [StringSplitOptions]::RemoveEmptyEntries
    ))
    if ($records.Count -ne 1) {
        throw "Tree path is not unique: $Path"
    }
    $tab = $records[0].IndexOf("`t", [StringComparison]::Ordinal)
    if ($tab -lt 0) {
        throw "Tree entry is malformed: $Path"
    }
    $metadata = $records[0].Substring(0, $tab).Split(" ")
    $entryPath = $records[0].Substring($tab + 1)
    if (
        $metadata.Count -ne 3 -or
        $entryPath -cne $Path -or
        $metadata[0] -notin @("100644", "100755") -or
        $metadata[1] -cne "blob" -or
        $metadata[2] -cnotmatch "^(?:[0-9a-f]{40}|[0-9a-f]{64})$"
    ) {
        throw "Tree entry is not a regular tracked file: $Path"
    }
    return [pscustomobject]@{
        mode = $metadata[0]
        object_id = $metadata[2]
        path = $entryPath
    }
}

function Get-GitBlobSize {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes
    )

    $sizeText = (Invoke-Git $Root @("cat-file", "-s", $ObjectId)).stdout.Trim()
    [int64]$size = 0
    if (
        -not [int64]::TryParse(
            $sizeText,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$size
        ) -or
        $size -lt 0 -or
        $size -gt $MaximumBytes
    ) {
        throw "Candidate blob size is invalid or exceeds its bound."
    }
    return $size
}

function Get-GitBlobEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][int64]$ExpectedSize,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes
    )

    $size = Get-GitBlobSize $Root $ObjectId $MaximumBytes
    if ($size -ne $ExpectedSize) {
        throw "Candidate blob size does not equal its approved size."
    }
    [byte[]]$bytes = Invoke-GitBytes `
        -Root $Root `
        -Arguments @("cat-file", "blob", $ObjectId) `
        -MaximumBytes ([int][Math]::Max(1, $MaximumBytes)) `
        -TimeoutSeconds $GitCommandTimeoutSeconds
    if ($bytes.Length -ne $size) {
        throw "Git blob read length does not equal its declared size."
    }
    return [pscustomobject]@{
        size_bytes = $size
        sha256 = Get-BytesSha256 $bytes
    }
}

function Read-GitBlobBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][int64]$MaximumBytes
    )

    $sizeText = (Invoke-Git $Root @("cat-file", "-s", $ObjectId)).stdout.Trim()
    [int64]$size = 0
    if (
        -not [int64]::TryParse(
            $sizeText,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$size
        ) -or
        $size -lt 0 -or
        $size -gt $MaximumBytes
    ) {
        throw "Git blob size is invalid or exceeds its read bound."
    }

    [byte[]]$bytes = Invoke-GitBytes `
        -Root $Root `
        -Arguments @("cat-file", "blob", $ObjectId) `
        -MaximumBytes ([int][Math]::Max(1, $MaximumBytes)) `
        -TimeoutSeconds $GitCommandTimeoutSeconds
    if ($bytes.Length -ne $size) {
        throw "Git blob read length does not equal its declared size."
    }
    return ,$bytes
}

function Get-ChangedPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    [byte[]]$bytes = Invoke-GitBytes $Root @(
        "diff",
        "--name-status",
        "-z",
        "--no-renames",
        "--no-ext-diff",
        $Base,
        $Candidate,
        "--"
    )
    $tokens = [Collections.Generic.List[byte[]]]::new()
    $start = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -ne 0) {
            continue
        }
        $length = $index - $start
        [byte[]]$token = [byte[]]::new($length)
        if ($length -gt 0) {
            [Array]::Copy($bytes, $start, $token, 0, $length)
        }
        $tokens.Add($token)
        $start = $index + 1
        if ($tokens.Count -gt 1024) {
            throw "Candidate diff exceeds the 512-path admission bound."
        }
    }
    if ($start -ne $bytes.Length) {
        throw "Git changed-path output lacks a terminal NUL."
    }
    if (($tokens.Count % 2) -ne 0) {
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
        if ($status -cnotmatch "^[A-Z][0-9]*$") {
            throw "Git changed-path status is unsupported: $status"
        }
        Assert-PortableRelativePath $path "changed path"
        $paths.Add($path)
        if ($paths.Count -gt 512) {
            throw "Candidate diff exceeds the 512-path admission bound."
        }
    }
    [string[]]$sorted = Get-OrdinalSorted @($paths)
    Assert-SortedUnique $sorted "changed paths"
    return ,$sorted
}

function Test-Approval {
    param(
        [Parameter(Mandatory = $true)][object]$Approval,
        [Parameter(Mandatory = $true)][string[]]$ChangedPaths,
        [Parameter(Mandatory = $true)][string]$GitRoot,
        [Parameter(Mandatory = $true)][string]$BaseRevision,
        [Parameter(Mandatory = $true)][string]$CandidateRevision,
        [Parameter(Mandatory = $true)]
        [Collections.Generic.Dictionary[string, object]]$EvidenceCache,
        [Parameter(Mandatory = $true)][object]$HashBudget
    )

    [string[]]$expectedPaths = @($Approval.changed_paths | ForEach-Object {
        [string]$_
    })
    Assert-SortedUnique $expectedPaths "approval changed_paths"
    if (-not (Test-OrdinalSequenceEqual $ChangedPaths $expectedPaths)) {
        return $false
    }

    $alreadyConsumed = Invoke-Git $GitRoot @(
        "merge-base",
        "--is-ancestor",
        [string]$Approval.required_ancestor,
        $BaseRevision
    ) -AllowFailure
    if ($alreadyConsumed.exit_code -eq 0) {
        return $false
    }
    if ($alreadyConsumed.exit_code -ne 1) {
        throw "Approval consumption ancestry could not be evaluated."
    }

    $ancestor = Invoke-Git $GitRoot @(
        "merge-base",
        "--is-ancestor",
        [string]$Approval.required_ancestor,
        $CandidateRevision
    ) -AllowFailure
    if ($ancestor.exit_code -eq 1) {
        return $false
    }
    if ($ancestor.exit_code -ne 0) {
        throw "Approval candidate ancestry could not be evaluated."
    }

    $artifacts = @($Approval.artifacts)
    [string[]]$artifactPaths = @($artifacts | ForEach-Object {
        [string]$_.path
    })
    Assert-SortedUnique $artifactPaths "approval artifacts"
    if (-not (Test-OrdinalSequenceEqual $expectedPaths $artifactPaths)) {
        throw "Approval artifact paths must equal its changed_paths."
    }

    $presentArtifacts = [Collections.Generic.List[object]]::new()
    $newObjects = [Collections.Generic.Dictionary[string, int64]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($artifact in $artifacts) {
        $relative = [string]$artifact.path
        Assert-PortableRelativePath $relative "approval artifact"
        $entry = Get-GitTreeEntry $GitRoot $CandidateRevision $relative
        if ([string]$artifact.state -eq "absent") {
            if ($null -ne $entry) {
                return $false
            }
            continue
        }
        if ($null -eq $entry) {
            return $false
        }
        if ([string]$entry.mode -cne [string]$artifact.mode) {
            return $false
        }
        $approvedSize = [int64]$artifact.size_bytes
        $actualSize = Get-GitBlobSize `
            -Root $GitRoot `
            -ObjectId ([string]$entry.object_id) `
            -MaximumBytes $MaximumArtifactBytes
        if ($actualSize -ne $approvedSize) {
            return $false
        }
        $presentArtifacts.Add([pscustomobject]@{
            artifact = $artifact
            entry = $entry
            size_bytes = $actualSize
        })
        if (
            -not $EvidenceCache.ContainsKey([string]$entry.object_id) -and
            -not $newObjects.ContainsKey([string]$entry.object_id)
        ) {
            $newObjects.Add([string]$entry.object_id, $actualSize)
        }
    }

    [int64]$additionalBytes = 0
    foreach ($size in $newObjects.Values) {
        $additionalBytes += $size
    }
    if ($additionalBytes -gt [int64]$HashBudget.remaining_bytes) {
        throw "Candidate blobs exceed the $MaximumTotalCandidateBlobBytes-byte total hashing budget."
    }

    foreach ($item in $presentArtifacts) {
        $objectId = [string]$item.entry.object_id
        if (-not $EvidenceCache.ContainsKey($objectId)) {
            $evidence = Get-GitBlobEvidence `
                -Root $GitRoot `
                -ObjectId $objectId `
                -ExpectedSize ([int64]$item.size_bytes) `
                -MaximumBytes $MaximumArtifactBytes
            $EvidenceCache.Add($objectId, $evidence)
            $HashBudget.remaining_bytes = (
                [int64]$HashBudget.remaining_bytes - [int64]$item.size_bytes
            )
        }
        $evidence = $EvidenceCache[$objectId]
        if (
            [int64]$evidence.size_bytes -ne [int64]$item.artifact.size_bytes -or
            [string]$evidence.sha256 -cne [string]$item.artifact.sha256
        ) {
            return $false
        }
    }
    return $true
}

$trusted = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).Path)
Assert-CleanGitProcessEnvironment
if ($Repository -cnotmatch "^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$") {
    throw "Repository identity is malformed."
}

Assert-PortableRelativePath $PolicyPath "policy path"
$policyRelative = $PolicyPath
Assert-GitInspectionEnvironment $trusted
$policySchema = Join-Path (
    Split-Path -Parent $PSScriptRoot
) "schemas/external-validation-authority-policy-v1.schema.json"
$baseIdentity = Get-GitCommitIdentity $trusted $BaseCommit "trusted base" -RequireHead
$candidateIdentity = Get-GitCommitIdentity $trusted $CandidateCommit "candidate"
$policyEntry = Get-GitTreeEntry $trusted $BaseCommit $policyRelative
if ($null -eq $policyEntry) {
    throw "Policy is not a regular file tracked by the trusted base."
}
$policyBytes = Read-GitBlobBytes `
    -Root $trusted `
    -ObjectId ([string]$policyEntry.object_id) `
    -MaximumBytes 1048576
$policySha256 = Get-BytesSha256 $policyBytes
Assert-StrictJson $policyBytes
$policyJson = [Text.UTF8Encoding]::new($false, $true).GetString($policyBytes)
if (-not (Test-Json -Json $policyJson -SchemaFile $policySchema -ErrorAction Stop)) {
    throw "External validation authority policy failed its schema."
}
$policy = $policyJson | ConvertFrom-Json -Depth 30
if ([string]$policy.repository -cne $Repository) {
    throw "Policy repository does not equal the declared repository."
}
[string[]]$mandatoryProtectedPaths = @(
    $policy.mandatory_protected_paths |
        ForEach-Object { [string]$_ }
)
Assert-SortedUnique $mandatoryProtectedPaths "mandatory protected paths"
foreach ($path in $mandatoryProtectedPaths) {
    Assert-PortableRelativePath $path "mandatory protected path"
}
if ($mandatoryProtectedPaths -cnotcontains $PolicyPath) {
    throw "Policy must list its own path as mandatory protected."
}
[string[]]$ruleIds = @($policy.protected_rules | ForEach-Object {
    [string]$_.rule_id
})
Assert-SortedUnique $ruleIds "protected rule IDs"
foreach ($rule in @($policy.protected_rules)) {
    Assert-PortableRulePath ([string]$rule.path) ([string]$rule.match)
}
[string[]]$approvalIds = @($policy.approved_change_sets | ForEach-Object {
    [string]$_.approval_id
})
Assert-SortedUnique $approvalIds "approval IDs"
$baseInCandidate = Invoke-Git $trusted @(
    "merge-base",
    "--is-ancestor",
    $BaseCommit,
    $CandidateCommit
) -AllowFailure
if ($baseInCandidate.exit_code -eq 1) {
    throw "Trusted base is not an ancestor of the candidate."
}
if ($baseInCandidate.exit_code -ne 0) {
    throw "Trusted-base ancestry could not be evaluated."
}

[string[]]$changedPaths = Get-ChangedPaths $trusted $BaseCommit $CandidateCommit
$protected = [Collections.Generic.List[string]]::new()
foreach ($path in $changedPaths) {
    $matched = $mandatoryProtectedPaths -ccontains $path
    if (-not $matched) {
        foreach ($rule in @($policy.protected_rules)) {
            $rulePath = [string]$rule.path
            if (
                (
                    [string]$rule.match -ceq "exact" -and
                    $path -ceq $rulePath
                ) -or
                (
                    [string]$rule.match -ceq "prefix" -and
                    $path.StartsWith($rulePath, [StringComparison]::Ordinal)
                )
            ) {
                $matched = $true
                break
            }
        }
    }
    if ($matched) {
        $protected.Add($path)
    }
}
[string[]]$protectedPaths = Get-OrdinalSorted @($protected)

$decision = "unprotected"
$approvalId = $null
if ($protectedPaths.Count -gt 0) {
    $matches = [Collections.Generic.List[object]]::new()
    $evidenceCache = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal
    )
    $hashBudget = [pscustomobject]@{
        remaining_bytes = $MaximumTotalCandidateBlobBytes
    }
    foreach ($approval in @($policy.approved_change_sets)) {
        if (
            Test-Approval `
                -Approval $approval `
                -ChangedPaths $changedPaths `
                -GitRoot $trusted `
                -BaseRevision $BaseCommit `
                -CandidateRevision $CandidateCommit `
                -EvidenceCache $evidenceCache `
                -HashBudget $hashBudget
        ) {
            $matches.Add($approval)
        }
    }
    if ($matches.Count -eq 0) {
        throw "Protected changes do not match an exact base-approved change set."
    }
    if ($matches.Count -ne 1) {
        throw "Protected changes ambiguously match more than one approval."
    }
    $decision = "approved-change-set"
    $approvalId = [string]$matches[0].approval_id
}

$assessment = [pscustomobject][ordered]@{
    schema = "rusty.morphospace.workflow.external_validation_authority_assessment.v1"
    policy_id = [string]$policy.policy_id
    policy_sha256 = $policySha256
    repository = $Repository
    base = $baseIdentity
    candidate = $candidateIdentity
    changed_paths = $changedPaths
    protected_paths = $protectedPaths
    decision = $decision
    approval_id = $approvalId
    candidate_code_executed = $false
    execution_attested = $false
    publication_authority = $false
    limitations = @(
        "Static admission only; no candidate code was executed.",
        "Execution, tests, and owner-effect evidence require separate trusted validation.",
        "This assessment does not authorize publication."
    )
}
$assessmentJson = $assessment | ConvertTo-Json -Depth 20
$assessmentSchema = Join-Path (
    Split-Path -Parent $PSScriptRoot
) "schemas/external-validation-authority-assessment-v1.schema.json"
if (-not (
    Test-Json -Json $assessmentJson -SchemaFile $assessmentSchema -ErrorAction Stop
)) {
    throw "External validation authority assessment failed its schema."
}

if ($OutPath) {
    $output = [IO.Path]::GetFullPath($OutPath)
    $prefix = $trusted.TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
    if (
        $output.Equals($trusted, [StringComparison]::OrdinalIgnoreCase) -or
        $output.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Assessment output must remain outside the Git checkout."
    }
    $parent = Split-Path -Parent $output
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Assessment output parent is absent: $parent"
    }
    Assert-NoLinkAncestor -Root $parent -Path $output
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($assessmentJson + "`n")
    $stream = [IO.FileStream]::new(
        $output,
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

if ($Json) {
    Write-Output $assessmentJson
} else {
    Write-Output $assessment
}
