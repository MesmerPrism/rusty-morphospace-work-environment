[CmdletBinding(DefaultParameterSetName = "Repository")]
param(
    [Parameter(ParameterSetName = "Repository")]
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter(Mandatory, ParameterSetName = "Evidence")]
    [string[]]$EvidencePath,

    [Parameter(Mandatory, ParameterSetName = "SelfTest")]
    [switch]$SelfTest,

    [switch]$Json,
    [switch]$NoThrow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-TextByteProfile {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $hasBom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
    $hasNul = $Bytes -contains 0
    $validUtf8 = $true
    try { $null = $utf8Strict.GetString($Bytes) } catch { $validUtf8 = $false }

    $crlf = 0
    $lf = 0
    $cr = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -eq 0x0D) {
            if (($index + 1) -lt $Bytes.Length -and $Bytes[$index + 1] -eq 0x0A) {
                $crlf++
                $index++
            } else {
                $cr++
            }
        } elseif ($Bytes[$index] -eq 0x0A) {
            $lf++
        }
    }

    return [pscustomobject][ordered]@{
        size_bytes = [int64]$Bytes.Length
        sha256 = Get-Sha256Hex -Bytes $Bytes
        valid_utf8 = $validUtf8
        utf8_bom = $hasBom
        nul_byte = $hasNul
        crlf_count = $crlf
        lf_count = $lf
        lone_cr_count = $cr
    }
}

function Get-TextByteReason {
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string]$Prefix
    )
    if ($Profile.nul_byte) { return "$Prefix-binary" }
    if (-not $Profile.valid_utf8) { return "$Prefix-invalid-utf8" }
    if ($Profile.utf8_bom) { return "$Prefix-utf8-bom" }
    if ($Profile.lone_cr_count -gt 0) { return "$Prefix-lone-cr" }
    if ($Profile.crlf_count -gt 0 -and $Profile.lf_count -gt 0) { return "$Prefix-mixed-line-endings" }
    if ($Profile.crlf_count -gt 0) { return "$Prefix-crlf" }
    return $null
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$InputText = ""
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = "git"
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if ($InputText -ne "") { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $stderr" }
        return $stdout
    } finally {
        $process.Dispose()
    }
}

function Get-GitBlobObjectId {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateSet("sha1", "sha256")][string]$ObjectFormat
    )
    [byte[]]$prefix = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    [byte[]]$objectBytes = [byte[]]::new($prefix.Length + $Bytes.Length)
    [Array]::Copy($prefix, 0, $objectBytes, 0, $prefix.Length)
    [Array]::Copy($Bytes, 0, $objectBytes, $prefix.Length, $Bytes.Length)
    [byte[]]$digest = if ($ObjectFormat -ceq "sha1") {
        [Security.Cryptography.SHA1]::HashData($objectBytes)
    } else {
        [Security.Cryptography.SHA256]::HashData($objectBytes)
    }
    return [Convert]::ToHexString($digest).ToLowerInvariant()
}

function Get-AttributeMap {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Paths
    )
    $map = @{}
    if ($Paths.Count -eq 0) { return $map }
    $arguments = @("check-attr", "text", "eol", "--") + $Paths
    $output = Invoke-GitText -Root $Root -Arguments $arguments
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -eq "") { continue }
        if ($line -notmatch '^(.*): (text|eol): (.*)$') { throw "Unexpected git check-attr output: $line" }
        $path = $Matches[1]
        $attribute = $Matches[2]
        $value = $Matches[3]
        if (-not $map.ContainsKey($path)) { $map[$path] = @{} }
        $map[$path][$attribute] = $value
    }
    return $map
}

function New-InspectionResult {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Head = ""
    )
    $reasons = @($Items | Where-Object status -ne "pass" | ForEach-Object reason_code | Sort-Object -Unique)
    $status = if (@($Items | Where-Object status -eq "fail").Count -gt 0) {
        "fail"
    } elseif (@($Items | Where-Object status -eq "incomplete").Count -gt 0) {
        "incomplete"
    } else {
        "pass"
    }
    return [pscustomobject][ordered]@{
        schema = "rusty.morphospace.workflow.canonical_text_byte_advisory.v1"
        mode = $Mode
        advisory_status = $status
        repository_head = $Head
        item_count = @($Items).Count
        pass_count = @($Items | Where-Object status -eq "pass").Count
        fail_count = @($Items | Where-Object status -eq "fail").Count
        incomplete_count = @($Items | Where-Object status -eq "incomplete").Count
        reason_codes = $reasons
        items = @($Items | Sort-Object path, source)
        state_mutation_performed = $false
        git_mutation_performed = $false
    }
}

function Invoke-EvidenceInspection {
    param([Parameter(Mandatory)][string[]]$Paths)
    $items = @()
    foreach ($path in $Paths) {
        $resolved = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
        [byte[]]$bytes = [IO.File]::ReadAllBytes($resolved)
        $profile = Get-TextByteProfile -Bytes $bytes
        $reason = Get-TextByteReason -Profile $profile -Prefix "eol002-evidence"
        $items += [pscustomobject][ordered]@{
            path = $resolved
            source = "evidence"
            classification = "utf8-lf"
            status = if ($null -eq $reason) { "pass" } else { "fail" }
            reason_code = if ($null -eq $reason) { "eol002-evidence-canonical" } else { $reason }
            bytes = $profile
        }
    }
    return New-InspectionResult -Mode "evidence" -Items $items
}

function Invoke-RepositoryInspection {
    param([Parameter(Mandatory)][string]$Root)
    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $inside = (Invoke-GitText -Root $resolvedRoot -Arguments @("rev-parse", "--is-inside-work-tree")).Trim()
    if ($inside -cne "true") { throw "RepositoryRoot is not a Git worktree." }
    $head = (Invoke-GitText -Root $resolvedRoot -Arguments @("rev-parse", "HEAD")).Trim()
    $objectFormat = (Invoke-GitText -Root $resolvedRoot -Arguments @("rev-parse", "--show-object-format")).Trim()
    $tracked = @((Invoke-GitText -Root $resolvedRoot -Arguments @("ls-files")) -split "`r?`n" | Where-Object { $_ -ne "" })
    $untracked = @((Invoke-GitText -Root $resolvedRoot -Arguments @("ls-files", "--others", "--exclude-standard")) -split "`r?`n" | Where-Object { $_ -ne "" })
    $paths = @($tracked + $untracked | Sort-Object -Unique)
    $attributes = Get-AttributeMap -Root $resolvedRoot -Paths $paths
    $index = @{}
    foreach ($line in ((Invoke-GitText -Root $resolvedRoot -Arguments @("ls-files", "--stage")) -split "`r?`n")) {
        if ($line -eq "") { continue }
        if ($line -notmatch '^([0-9]{6}) ([0-9a-f]+) 0\t(.*)$') { throw "Unsupported index entry: $line" }
        $index[$Matches[3]] = [pscustomobject]@{ mode = $Matches[1]; oid = $Matches[2] }
    }
    $items = @()

    foreach ($path in $paths) {
        if ([IO.Path]::IsPathRooted($path) -or $path -match '(^|/)\.\.(/|$)') { throw "Unsafe Git path: $path" }
        $text = [string]$attributes[$path]["text"]
        $eol = [string]$attributes[$path]["eol"]
        $classification = if ($text -ceq "set" -and $eol -ceq "lf") {
            "canonical-utf8-lf"
        } elseif ($text -ceq "unset") {
            "legacy-byte-exact"
        } else {
            "unclassified"
        }

        if ($classification -ceq "unclassified") {
            $items += [pscustomobject][ordered]@{
                path = $path; source = "attributes"; classification = $classification
                status = "incomplete"; reason_code = "eol002-classification-missing"
                text_attribute = $text; eol_attribute = $eol; bytes = $null
            }
            continue
        }

        $fullPath = Join-Path $resolvedRoot ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $items += [pscustomobject][ordered]@{
                path = $path; source = "working-tree"; classification = $classification
                status = "incomplete"; reason_code = "eol002-working-tree-file-missing"
                text_attribute = $text; eol_attribute = $eol; bytes = $null
            }
            continue
        }

        [byte[]]$workingBytes = [IO.File]::ReadAllBytes($fullPath)
        $workingProfile = Get-TextByteProfile -Bytes $workingBytes
        $workingReason = if ($classification -ceq "canonical-utf8-lf") {
            Get-TextByteReason -Profile $workingProfile -Prefix "eol002-covered"
        } else { $null }
        $items += [pscustomobject][ordered]@{
            path = $path; source = "working-tree"; classification = $classification
            status = if ($null -eq $workingReason) { "pass" } else { "fail" }
            reason_code = if ($null -eq $workingReason) { "eol002-byte-policy-satisfied" } else { $workingReason }
            text_attribute = $text; eol_attribute = $eol; bytes = $workingProfile
        }

        if ($path -in $tracked) {
            $entry = $index[$path]
            $workingOid = Get-GitBlobObjectId -Bytes $workingBytes -ObjectFormat $objectFormat
            $indexReason = if ($entry.mode -notin @("100644", "100755")) {
                "eol002-index-file-mode-unsupported"
            } elseif ($workingOid -cne $entry.oid) {
                "eol002-index-working-tree-byte-mismatch"
            } elseif ($classification -ceq "canonical-utf8-lf") {
                Get-TextByteReason -Profile $workingProfile -Prefix "eol002-index-covered"
            } else {
                $null
            }
            $items += [pscustomobject][ordered]@{
                path = $path; source = "index"; classification = $classification
                status = if ($null -eq $indexReason) { "pass" } else { "fail" }
                reason_code = if ($null -eq $indexReason) { "eol002-byte-policy-satisfied" } else { $indexReason }
                text_attribute = $text; eol_attribute = $eol; bytes = if ($workingOid -ceq $entry.oid) { $workingProfile } else { $null }
                index_oid = $entry.oid; working_tree_oid = $workingOid
            }
        }
    }
    return New-InspectionResult -Mode "repository" -Items $items -Head $head
}

function Write-FixtureBytes {
    param([string]$Path, [byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent) }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Initialize-FixtureRepository {
    param([string]$Root)
    [void](New-Item -ItemType Directory -Path $Root)
    $null = Invoke-GitText -Root $Root -Arguments @("init", "--quiet")
    $null = Invoke-GitText -Root $Root -Arguments @("config", "user.name", "EOL Fixture")
    $null = Invoke-GitText -Root $Root -Arguments @("config", "user.email", "eol-fixture@example.invalid")
}

function Assert-Reason {
    param([object]$Result, [string]$ExpectedStatus, [string]$ExpectedReason)
    if ($Result.advisory_status -cne $ExpectedStatus) { throw "Expected $ExpectedStatus, got $($Result.advisory_status)." }
    if ($ExpectedReason -ne "" -and $ExpectedReason -notin @($Result.reason_codes)) { throw "Expected reason $ExpectedReason." }
}

function Invoke-SelfTest {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("eol002-selftest-" + [guid]::NewGuid().ToString("N"))
    try {
        [void](New-Item -ItemType Directory -Path $temp)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $evidenceCases = @(
            @{ name = "lf"; bytes = $utf8.GetBytes("a`nb`n"); status = "pass"; reason = "" },
            @{ name = "crlf"; bytes = $utf8.GetBytes("a`r`nb`r`n"); status = "fail"; reason = "eol002-evidence-crlf" },
            @{ name = "mixed"; bytes = $utf8.GetBytes("a`r`nb`n"); status = "fail"; reason = "eol002-evidence-mixed-line-endings" },
            @{ name = "bom"; bytes = [byte[]](0xEF,0xBB,0xBF) + $utf8.GetBytes("a`n"); status = "fail"; reason = "eol002-evidence-utf8-bom" },
            @{ name = "binary"; bytes = [byte[]](0x01,0x00,0x02); status = "fail"; reason = "eol002-evidence-binary" }
        )
        foreach ($case in $evidenceCases) {
            $path = Join-Path $temp ("evidence-" + $case.name)
            Write-FixtureBytes -Path $path -Bytes $case.bytes
            Assert-Reason -Result (Invoke-EvidenceInspection -Paths @($path)) -ExpectedStatus $case.status -ExpectedReason $case.reason
        }

        foreach ($case in @(
            @{ name = "lf"; bytes = $utf8.GetBytes("a`nb`n"); status = "pass"; reason = "" },
            @{ name = "crlf"; bytes = $utf8.GetBytes("a`r`nb`r`n"); status = "fail"; reason = "eol002-covered-crlf" },
            @{ name = "mixed"; bytes = $utf8.GetBytes("a`r`nb`n"); status = "fail"; reason = "eol002-covered-mixed-line-endings" },
            @{ name = "bom"; bytes = [byte[]](0xEF,0xBB,0xBF) + $utf8.GetBytes("a`n"); status = "fail"; reason = "eol002-covered-utf8-bom" },
            @{ name = "binary"; bytes = [byte[]](0x01,0x00,0x02); status = "fail"; reason = "eol002-covered-binary" }
        )) {
            $repo = Join-Path $temp ("repo-" + $case.name)
            Initialize-FixtureRepository -Root $repo
            Write-FixtureBytes -Path (Join-Path $repo ".gitattributes") -Bytes $utf8.GetBytes("* -text`ncovered.txt text eol=lf`nbinary.bin -text`n")
            Write-FixtureBytes -Path (Join-Path $repo "covered.txt") -Bytes $case.bytes
            Write-FixtureBytes -Path (Join-Path $repo "binary.bin") -Bytes ([byte[]](0x01,0x00,0x02))
            $null = Invoke-GitText -Root $repo -Arguments @("add", "--", ".gitattributes", "covered.txt", "binary.bin")
            $null = Invoke-GitText -Root $repo -Arguments @("commit", "--quiet", "-m", "fixture")
            $result = Invoke-RepositoryInspection -Root $repo
            Assert-Reason -Result $result -ExpectedStatus $case.status -ExpectedReason $case.reason
        }

        $source = Join-Path $temp "source"
        Initialize-FixtureRepository -Root $source
        Write-FixtureBytes -Path (Join-Path $source ".gitattributes") -Bytes $utf8.GetBytes("* -text`n.gitattributes text eol=lf`ncovered.txt text eol=lf`n")
        Write-FixtureBytes -Path (Join-Path $source "covered.txt") -Bytes $utf8.GetBytes("one`ntwo`n")
        Write-FixtureBytes -Path (Join-Path $source "legacy.txt") -Bytes $utf8.GetBytes("one`r`ntwo`r`n")
        $null = Invoke-GitText -Root $source -Arguments @("add", "--all")
        $null = Invoke-GitText -Root $source -Arguments @("commit", "--quiet", "-m", "fixture")
        foreach ($autocrlf in @("true", "false")) {
            $clone = Join-Path $temp ("clone-" + $autocrlf)
            $null = Invoke-GitText -Root $temp -Arguments @("-c", "core.autocrlf=$autocrlf", "clone", "--quiet", $source, $clone)
            $result = Invoke-RepositoryInspection -Root $clone
            Assert-Reason -Result $result -ExpectedStatus "pass" -ExpectedReason ""
            $covered = Get-TextByteProfile -Bytes ([IO.File]::ReadAllBytes((Join-Path $clone "covered.txt")))
            $legacy = Get-TextByteProfile -Bytes ([IO.File]::ReadAllBytes((Join-Path $clone "legacy.txt")))
            if ($covered.crlf_count -ne 0 -or $covered.lf_count -ne 2) { throw "Covered LF bytes changed under core.autocrlf=$autocrlf." }
            if ($legacy.crlf_count -ne 2 -or $legacy.lf_count -ne 0) { throw "Legacy byte-exact bytes changed under core.autocrlf=$autocrlf." }
        }
        Write-Output "Canonical text-byte self-test passed (LF, CRLF, mixed, BOM, binary, core.autocrlf true/false, and evidence preflight)."
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$result = if ($PSCmdlet.ParameterSetName -ceq "Evidence") {
    Invoke-EvidenceInspection -Paths $EvidencePath
} else {
    Invoke-RepositoryInspection -Root $RepositoryRoot
}

if ($Json) {
    Write-Output ($result | ConvertTo-Json -Depth 12)
} else {
    Write-Output ("Canonical text-byte advisory {0}: {1} item(s), {2} failure(s), {3} incomplete." -f $result.advisory_status, $result.item_count, $result.fail_count, $result.incomplete_count)
}
if (-not $NoThrow -and $result.advisory_status -cne "pass") {
    throw "Canonical text-byte advisory did not pass: $($result.reason_codes -join ', ')."
}
