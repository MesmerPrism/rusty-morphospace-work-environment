Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Microsoft.PowerShell.Core\Import-Module ([IO.Path]::Combine($PSScriptRoot,"MorphospaceProtocolCommon.psm1"))

if (-not ('MorphospaceBoundedMemoryStream' -as [type])) {
    Microsoft.PowerShell.Utility\Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public sealed class MorphospaceBoundedMemoryStream : MemoryStream
{
    private readonly long maximumLength;

    public MorphospaceBoundedMemoryStream(long maximumLength)
    {
        if (maximumLength < 1) throw new ArgumentOutOfRangeException("maximumLength");
        this.maximumLength = maximumLength;
    }

    private void CheckWrite(int count)
    {
        if (count < 0 || Length > maximumLength - count)
            throw new InvalidOperationException("Morphospace process output limit exceeded.");
    }

    public override void Write(byte[] buffer, int offset, int count)
    {
        CheckWrite(count);
        base.Write(buffer, offset, count);
    }

    public override void WriteByte(byte value)
    {
        CheckWrite(1);
        base.WriteByte(value);
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        CheckWrite(count);
        return base.WriteAsync(buffer, offset, count, cancellationToken);
    }
}
'@
}

function Sort-MorphospaceOrdinalStrings {
    param([AllowEmptyCollection()][string[]]$Values = @())
    $copyList=[Collections.Generic.List[string]]::new();foreach($value in $Values){$copyList.Add([string]$value)};$copy=@($copyList.ToArray())
    [Array]::Sort($copy, [System.StringComparer]::Ordinal)
    return @($copy)
}

function Get-MorphospaceBoundExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Microsoft.PowerShell.Core\Get-Command $Name -CommandType Application -ErrorAction Stop | Microsoft.PowerShell.Utility\Select-Object -First 1
    $path = [System.IO.Path]::GetFullPath([string]$command.Source)
    if (-not [IO.File]::Exists($path)) { throw "Bound executable is missing: $path" }
    return [pscustomobject][ordered]@{ path = $path; sha256 = Get-MorphospaceFileSha256 -Path $path }
}

function ConvertTo-MorphospaceWindowsArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-MorphospaceBoundProcessBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60,
        [ValidateRange(1024, 268435456)][int]$MaxOutputBytes = 67108864,
        [string]$ExpectedExecutableSha256 = '',
        [switch]$AllowFailure
    )
    $executablePath = [System.IO.Path]::GetFullPath($Executable)
    $executableHashBefore = Get-MorphospaceFileSha256 -Path $executablePath
    if ($ExpectedExecutableSha256 -and $executableHashBefore -cne $ExpectedExecutableSha256) {
        throw "Bound executable changed before invocation: $executablePath"
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $executablePath
    $psi.WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($psi.PSObject.Properties.Name -contains 'ArgumentList') {
        foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add([string]$argument) }
    } else {
        $quotedArguments=[Collections.Generic.List[string]]::new();foreach($argument in $Arguments){$quotedArguments.Add((ConvertTo-MorphospaceWindowsArgument -Value ([string]$argument)))};$psi.Arguments=($quotedArguments.ToArray()-join' ')
    }
    if ($psi.PSObject.Properties.Name -contains 'Environment') { $environment = $psi.Environment } else { $environment = $psi.EnvironmentVariables }
    $dynamicGitConfigList=[Collections.Generic.List[string]]::new();foreach($environmentName in $environment.Keys){$candidateEnvironmentName=[string]$environmentName;if($candidateEnvironmentName.StartsWith('GIT_CONFIG_KEY_',[StringComparison]::OrdinalIgnoreCase)-or$candidateEnvironmentName.StartsWith('GIT_CONFIG_VALUE_',[StringComparison]::OrdinalIgnoreCase)){$dynamicGitConfigList.Add($candidateEnvironmentName)}};$dynamicGitConfigNames=@($dynamicGitConfigList.ToArray())
    foreach ($name in @(
        'GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_COMMON_DIR','GIT_NAMESPACE',
        'GIT_CONFIG','GIT_CONFIG_COUNT','GIT_CONFIG_PARAMETERS','GIT_SHALLOW_FILE',
        'GIT_CEILING_DIRECTORIES','GIT_DISCOVERY_ACROSS_FILESYSTEM','GIT_EXEC_PATH',
        'GIT_TEMPLATE_DIR','GIT_QUARANTINE_PATH','GIT_GLOB_PATHSPECS',
        'GIT_NOGLOB_PATHSPECS','GIT_LITERAL_PATHSPECS','GIT_ICASE_PATHSPECS',
        'GIT_ASKPASS','SSH_ASKPASS','GIT_SSH','GIT_SSH_COMMAND'
    ) + $dynamicGitConfigNames) { [void]$environment.Remove($name) }
    $environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $environment['GIT_CONFIG_GLOBAL'] = 'NUL'
    $environment['GIT_CONFIG_SYSTEM'] = 'NUL'
    $environment['GIT_OPTIONAL_LOCKS'] = '0'
    $environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $environment['GIT_ATTR_NOSYSTEM'] = '1'
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    $environment['GIT_EXTERNAL_DIFF'] = ''
    $environment['GIT_DIFF_OPTS'] = ''
    $environment['LC_ALL'] = 'C'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $stdout = [MorphospaceBoundedMemoryStream]::new($MaxOutputBytes)
    $stderr = [MorphospaceBoundedMemoryStream]::new($MaxOutputBytes)
    try {
        if (-not $process.Start()) { throw "Failed to launch bound executable '$Executable'." }
        $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited) {
            if ($stdoutCopy.IsFaulted -or $stderrCopy.IsFaulted) {
                try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
                throw "Bound process output exceeded $MaxOutputBytes bytes: $Executable"
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
                throw "Bound process exceeded $TimeoutSeconds seconds: $Executable"
            }
            [Threading.Thread]::Sleep(10)
        }
        try {
            [void]$stdoutCopy.GetAwaiter().GetResult()
            [void]$stderrCopy.GetAwaiter().GetResult()
        } catch {
            throw "Bound process output exceeded $MaxOutputBytes bytes: $Executable"
        }
        $exit = $process.ExitCode
        $outBytes = $stdout.ToArray()
        $errBytes = $stderr.ToArray()
    } finally {
        $process.Dispose(); $stdout.Dispose(); $stderr.Dispose()
    }
    $executableHashAfter = Get-MorphospaceFileSha256 -Path $executablePath
    if ($executableHashAfter -cne $executableHashBefore -or ($ExpectedExecutableSha256 -and $executableHashAfter -cne $ExpectedExecutableSha256)) {
        throw "Bound executable changed during invocation: $executablePath"
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $errorText = try { $utf8.GetString($errBytes) } catch { '<invalid-utf8-stderr>' }
    if ($exit -ne 0 -and -not $AllowFailure) {
        throw "Bound process failed ($exit): $Executable $($Arguments -join ' ')`n$errorText"
    }
    return [pscustomobject]@{ exit_code = $exit; stdout = [byte[]]$outBytes; stderr = [byte[]]$errBytes; stderr_text = $errorText }
}

function Invoke-MorphospaceBoundGitBytes {
    param(
        [Parameter(Mandatory = $true)][string]$GitExecutable,
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$ExpectedExecutableSha256 = '',
        [object]$SafetyContext = $null,
        [switch]$AllowFailure
    )
    $baseArguments = @(
        '--no-optional-locks','--no-replace-objects','--literal-pathspecs',
        '-c','core.quotepath=false','-c','color.ui=false','-c','core.fsmonitor=false',
        '-c','diff.external=','-c','core.hooksPath=NUL'
    )
    if($null-ne$SafetyContext){
        $safeCallerConfig=[Collections.Generic.List[string]]::new();$remaining=[Collections.Generic.List[string]]::new();$index=0
        while($index-lt$Arguments.Count-and[string]$Arguments[$index]-ceq'-c'){if($index+1-ge$Arguments.Count){throw 'Truncated Git -c option.'};$setting=[string]$Arguments[$index+1];$key=($setting-split'=',2)[0].ToLowerInvariant();if(@('core.safecrlf','core.autocrlf')-cnotcontains$key){throw "Observation Git command attempted an unapproved config override: $key"};$safeCallerConfig.Add('-c');$safeCallerConfig.Add($setting);$index+=2}
        for(;$index-lt$Arguments.Count;$index++){$argument=[string]$Arguments[$index];if($argument-ceq'-c'-or$argument.StartsWith('--config-env',[StringComparison]::Ordinal)-or$argument-ceq'--ext-diff'-or$argument-ceq'--textconv'){throw "Observation Git command attempted to re-enable an unsafe surface: $argument"};$remaining.Add($argument)}
        if($remaining.Count-eq0-or[string]$remaining[0]-ceq'config'){throw 'Observation safety context cannot execute a missing/config-mutating Git subcommand.'}
        $args=$baseArguments+@($safeCallerConfig.ToArray())+@($SafetyContext.override_arguments)+@($remaining.ToArray())
    }else{$args=$baseArguments+@($Arguments)}
    return Invoke-MorphospaceBoundProcessBytes -Executable $GitExecutable -Arguments $args -WorkingDirectory $RepositoryPath -ExpectedExecutableSha256 $ExpectedExecutableSha256 -AllowFailure:$AllowFailure
}

function ConvertFrom-MorphospaceUtf8Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try { return $utf8.GetString($Bytes) } catch { throw "Git emitted non-UTF-8 path/control evidence." }
}

function Split-MorphospaceNulBytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Length -eq 0) { return @() }
    $text = ConvertFrom-MorphospaceUtf8Bytes -Bytes $Bytes
    $parts = @($text.Split([char]0))
    if ($parts.Count -gt 0 -and $parts[-1] -eq '') { $parts = @($parts[0..($parts.Count - 2)]) }
    return @($parts)
}

function Resolve-MorphospaceGitReportedPath {
    param([string]$RepositoryPath,[byte[]]$Bytes,[string]$Context)
    $reported=(ConvertFrom-MorphospaceUtf8Bytes $Bytes).Trim();if(-not$reported){throw "$Context returned an empty path."}
    return [IO.Path]::GetFullPath($(if([IO.Path]::IsPathRooted($reported)){$reported}else{[IO.Path]::Combine($RepositoryPath,$reported)}))
}

function New-MorphospaceLeasedEvidenceFile {
    param([string]$RepositoryRoot,[string]$Path,[string]$Context)
    $full=[IO.Path]::GetFullPath($Path);Assert-MorphospaceNoReparseAncestor $RepositoryRoot $full
    if(-not[IO.File]::Exists($full)){return $null}
    $stream=[IO.FileStream]::new($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{if($stream.Length-gt16777216){throw "$Context exceeds 16 MiB."};$result=[pscustomobject]@{path=$full;length=[long]$stream.Length;sha256=(Get-MorphospaceStreamSha256 $stream);stream=$stream;context=$Context};$stream=$null;return $result}finally{if($null-ne$stream){$stream.Dispose()}}
}

function Get-MorphospaceGitAttributePaths {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$ExpectedGitHash)
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$pending=[Collections.Generic.Stack[string]]::new();$pending.Push($RepositoryPath)
    while($pending.Count-gt0){$directory=$pending.Pop();foreach($child in @([IO.Directory]::GetFileSystemEntries($directory))){$attributes=[IO.File]::GetAttributes($child);if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Reparse path rejected while discovering Git attributes: $child"};if(($attributes-band[IO.FileAttributes]::Directory)-ne0){if([IO.Path]::GetFileName($child)-cne'.git'){$pending.Push($child)}}elseif([IO.Path]::GetFileName($child)-ceq'.gitattributes'){[void]$paths.Add([IO.Path]::GetFullPath($child))}}}
    $infoResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('rev-parse','--git-path','info/attributes') -ExpectedExecutableSha256 $ExpectedGitHash
    $infoPath=Resolve-MorphospaceGitReportedPath $RepositoryPath $infoResult.stdout 'Git info attributes path';if([IO.File]::Exists($infoPath)){[void]$paths.Add($infoPath)}
    $result=@($paths);[Array]::Sort($result,[StringComparer]::Ordinal);return $result
}

function Get-MorphospaceGitConfigKeyNames {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$ExpectedGitHash,[string]$Pattern)
    $result=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('config','--no-includes','--null','--name-only','--get-regexp',$Pattern) -ExpectedExecutableSha256 $ExpectedGitHash -AllowFailure
    if($result.exit_code-eq1){return @()};if($result.exit_code-ne0){throw "Safe Git config-key discovery failed for '$Pattern'."}
    $names=[Collections.Generic.List[string]]::new();foreach($token in @(Split-MorphospaceNulBytes $result.stdout)){$name=([string]$token).Trim();if($name){$names.Add($name)}};$array=@($names.ToArray());[Array]::Sort($array,[StringComparer]::Ordinal);return $array
}

function Get-MorphospaceGitFilterDrivers {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$ExpectedGitHash)
    $drivers=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($key in @(Get-MorphospaceGitConfigKeyNames $GitExecutable $RepositoryPath $ExpectedGitHash '^filter\.')){$match=[regex]::Match($key,'^filter\.(?<driver>.+)\.(?<property>[^.]+)$',[Text.RegularExpressions.RegexOptions]::IgnoreCase);if(-not$match.Success-or@('clean','process','smudge','required')-cnotcontains$match.Groups['property'].Value.ToLowerInvariant()){throw "Unsafe or unknown Git filter configuration key: $key"};$driver=$match.Groups['driver'].Value;if($driver-notmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'){throw "Unsafe Git filter driver name: $driver"};[void]$drivers.Add($driver)}
    $result=@($drivers);[Array]::Sort($result,[StringComparer]::Ordinal);return $result
}

function New-MorphospaceGitSafetyContext {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$ExpectedGitHash)
    $leases=[Collections.Generic.List[object]]::new()
    try{
        $configResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('rev-parse','--git-path','config') -ExpectedExecutableSha256 $ExpectedGitHash;$configPath=Resolve-MorphospaceGitReportedPath $RepositoryPath $configResult.stdout 'Git config path';$configLease=New-MorphospaceLeasedEvidenceFile $RepositoryPath $configPath 'Git local config';if($null-eq$configLease){throw 'Git local config must exist and remain leased for evidence observation.'};$leases.Add($configLease)
        if(@(Get-MorphospaceGitConfigKeyNames $GitExecutable $RepositoryPath $ExpectedGitHash '^extensions\.worktreeconfig$').Count-ne0){throw 'Git extensions.worktreeConfig is not accepted for evidence observation.'}
        foreach($key in @(Get-MorphospaceGitConfigKeyNames $GitExecutable $RepositoryPath $ExpectedGitHash '^(include|includeif)\.')){throw "Git config includes are not accepted for evidence observation: $key"}
        $customAttributes=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('config','--no-includes','--get','core.attributesfile') -ExpectedExecutableSha256 $ExpectedGitHash -AllowFailure;if($customAttributes.exit_code-eq0-and(ConvertFrom-MorphospaceUtf8Bytes $customAttributes.stdout).Trim()){throw 'Custom core.attributesFile is not accepted for evidence observation.'}elseif($customAttributes.exit_code-notin@(0,1)){throw 'Git core.attributesFile discovery failed.'}
        $attributePaths=@(Get-MorphospaceGitAttributePaths $GitExecutable $RepositoryPath $ExpectedGitHash);foreach($path in $attributePaths){$lease=New-MorphospaceLeasedEvidenceFile $RepositoryPath $path 'Git attributes';if($null-ne$lease){$leases.Add($lease)}}
        $drivers=@(Get-MorphospaceGitFilterDrivers $GitExecutable $RepositoryPath $ExpectedGitHash);$overrides=[Collections.Generic.List[string]]::new();foreach($driver in $drivers){foreach($property in @('clean','process','smudge')){$overrides.Add('-c');$overrides.Add("filter.$driver.$property=")};$overrides.Add('-c');$overrides.Add("filter.$driver.required=false")}
        return [pscustomobject]@{override_arguments=@($overrides.ToArray());filter_drivers=$drivers;attribute_paths=$attributePaths;config_paths=@($configPath);leases=$leases}
    }catch{foreach($lease in $leases){$lease.stream.Dispose()};throw}
}

function Test-MorphospaceGitSafetyContext {
    param([object]$Context,[string]$GitExecutable,[string]$RepositoryPath,[string]$ExpectedGitHash)
    foreach($lease in @($Context.leases)){if([long]$lease.stream.Length-ne[long]$lease.length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne[string]$lease.sha256){throw "Git config/attributes changed under lease: $([string]$lease.path)"}}
    if(@(Get-MorphospaceGitConfigKeyNames $GitExecutable $RepositoryPath $ExpectedGitHash '^extensions\.worktreeconfig$').Count-ne0){throw 'Git extensions.worktreeConfig appeared during evidence observation.'}
    $attributes=@(Get-MorphospaceGitAttributePaths $GitExecutable $RepositoryPath $ExpectedGitHash);if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$attributes}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=@($Context.attribute_paths)}))){throw 'Git attributes surface set changed during observation.'}
    $drivers=@(Get-MorphospaceGitFilterDrivers $GitExecutable $RepositoryPath $ExpectedGitHash);if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$drivers}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=@($Context.filter_drivers)}))){throw 'Git filter configuration changed during observation.'}
}

function Close-MorphospaceGitSafetyContext {
    param([object]$Context)
    if($null-ne$Context){foreach($lease in @($Context.leases)){$lease.stream.Dispose()}}
}

function Test-MorphospaceObservationPathAllowed {
    param([string]$Path, [object[]]$AllowedPaths)
    $candidate = ConvertTo-MorphospaceProtocolRelativePath -Path $Path
    foreach ($raw in @($AllowedPaths)) {
        $allowed = ConvertTo-MorphospaceProtocolRelativePath -Path ([string]$raw).TrimEnd('/', '\')
        if ($candidate.Equals($allowed, [System.StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($allowed + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-MorphospacePorcelainV2Status {
    param([string]$GitExecutable, [string]$RepositoryPath, [string]$ExpectedGitHash = '',[object]$SafetyContext=$null)
    $result = Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('status', '--porcelain=v2', '-z', '--untracked-files=all') -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    $tokens = @(Split-MorphospaceNulBytes -Bytes $result.stdout)
    $records = [Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $tokens.Count) {
        $record = [string]$tokens[$i]; $i++
        if ($record.StartsWith('1 ')) {
            $parts = $record -split ' ', 9
            if ($parts.Count -ne 9) { throw 'Damaged porcelain-v2 ordinary record.' }
            [void]$records.Add([pscustomobject][ordered]@{ record_type='ordinary'; xy=$parts[1]; path=(ConvertTo-MorphospaceProtocolRelativePath $parts[8]); original_path=$null; raw=$record })
        } elseif ($record.StartsWith('2 ')) {
            $parts = $record -split ' ', 10
            if ($parts.Count -ne 10 -or $i -ge $tokens.Count) { throw 'Damaged porcelain-v2 rename record.' }
            $original = [string]$tokens[$i]; $i++
            [void]$records.Add([pscustomobject][ordered]@{ record_type='rename'; xy=$parts[1]; path=(ConvertTo-MorphospaceProtocolRelativePath $parts[9]); original_path=(ConvertTo-MorphospaceProtocolRelativePath $original); raw=($record+[char]0+$original) })
        } elseif ($record.StartsWith('u ')) {
            $parts = $record -split ' ', 11
            if ($parts.Count -ne 11) { throw 'Damaged porcelain-v2 unmerged record.' }
            [void]$records.Add([pscustomobject][ordered]@{ record_type='unmerged'; xy=$parts[1]; path=(ConvertTo-MorphospaceProtocolRelativePath $parts[10]); original_path=$null; raw=$record })
        } elseif ($record.StartsWith('? ')) {
            [void]$records.Add([pscustomobject][ordered]@{ record_type='untracked'; xy='??'; path=(ConvertTo-MorphospaceProtocolRelativePath $record.Substring(2)); original_path=$null; raw=$record })
        } elseif ($record.StartsWith('! ')) { continue }
        else { throw "Unknown porcelain-v2 record '$record'." }
    }
    return [pscustomobject][ordered]@{
        raw_sha256 = Get-MorphospaceSha256Bytes -Bytes $result.stdout
        records = @($records.ToArray())
    }
}

function Get-MorphospaceDiffNameStatus {
    param([string]$GitExecutable, [string]$RepositoryPath, [string]$BaseRevision, [string]$ExpectedGitHash = '',[object]$SafetyContext=$null)
    $result = Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('diff','--name-status','-z','--find-renames','--no-ext-diff','--no-textconv',$BaseRevision,'--') -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    $tokens = @(Split-MorphospaceNulBytes $result.stdout)
    $changes = [Collections.Generic.List[object]]::new()
    $i=0
    while($i -lt $tokens.Count){
        $status=[string]$tokens[$i]; $i++
        if($i -ge $tokens.Count){throw 'Damaged NUL name-status evidence.'}
        $path=[string]$tokens[$i]; $i++
        $old=$null
        if($status.StartsWith('R') -or $status.StartsWith('C')){
            $old=ConvertTo-MorphospaceProtocolRelativePath $path
            if($i -ge $tokens.Count){throw 'Damaged NUL rename/copy evidence.'}
            $path=[string]$tokens[$i]; $i++
        }
        [void]$changes.Add([pscustomobject][ordered]@{ status=$status; path=(ConvertTo-MorphospaceProtocolRelativePath $path); original_path=$old })
    }
    return @($changes.ToArray())
}

function Get-MorphospaceGitTreeEntry {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$Revision,[string]$Path,[string]$ExpectedGitHash='',[object]$SafetyContext=$null)
    $r=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('ls-tree','-z',$Revision,'--',$Path) -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext -AllowFailure
    if($r.exit_code -ne 0 -or $r.stdout.Length -eq 0){return $null}
    $tokens=@(Split-MorphospaceNulBytes $r.stdout); if($tokens.Count -ne 1){throw "Ambiguous tree entry for '$Path'."}
    $m=[regex]::Match($tokens[0],'^(?<mode>[0-9]{6})\s+(?<kind>\S+)\s+(?<oid>[0-9a-f]{40,64})\t')
    if(-not $m.Success){throw "Damaged tree entry for '$Path'."}
    return [pscustomobject][ordered]@{mode=$m.Groups['mode'].Value;kind=$m.Groups['kind'].Value;oid=$m.Groups['oid'].Value}
}

function Get-MorphospaceGitIndexEntries {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$Path,[string]$ExpectedGitHash='',[object]$SafetyContext=$null)
    $r=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('ls-files','--stage','-z','--',$Path) -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    $list=[Collections.Generic.List[object]]::new()
    foreach($token in @(Split-MorphospaceNulBytes $r.stdout)){
        $m=[regex]::Match($token,'^(?<mode>[0-9]{6})\s+(?<oid>[0-9a-f]{40,64})\s+(?<stage>[0-3])\t')
        if(-not $m.Success){throw "Damaged index entry for '$Path'."}
        [void]$list.Add([pscustomobject][ordered]@{mode=$m.Groups['mode'].Value;oid=$m.Groups['oid'].Value;stage=[int]$m.Groups['stage'].Value})
    }
    return @($list.ToArray())
}

function Get-MorphospaceGitTreeEntryMap {
    param(
        [string]$GitExecutable,
        [string]$RepositoryPath,
        [string]$Revision,
        [string[]]$Paths,
        [string]$ExpectedGitHash='',
        [object]$SafetyContext=$null
    )
    $requested=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($path in $Paths){[void]$requested.Add((ConvertTo-MorphospaceProtocolRelativePath $path))}
    $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if($requested.Count-eq0){return $map}
    $result=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('ls-tree','-r','-z',$Revision,'--') -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    foreach($token in @(Split-MorphospaceNulBytes $result.stdout)){
        $match=[regex]::Match($token,'^(?<mode>[0-9]{6})\s+(?<kind>\S+)\s+(?<oid>[0-9a-f]{40,64})\t(?<path>.+)$')
        if(-not$match.Success){throw "Damaged recursive tree entry at '$Revision'."}
        $path=ConvertTo-MorphospaceProtocolRelativePath $match.Groups['path'].Value
        if(-not$requested.Contains($path)){continue}
        if($map.ContainsKey($path)){throw "Recursive tree repeats '$path' at '$Revision'."}
        $map[$path]=[pscustomobject][ordered]@{mode=$match.Groups['mode'].Value;kind=$match.Groups['kind'].Value;oid=$match.Groups['oid'].Value}
    }
    return $map
}

function Get-MorphospaceGitIndexEntryMap {
    param(
        [string]$GitExecutable,
        [string]$RepositoryPath,
        [string[]]$Paths,
        [string]$ExpectedGitHash='',
        [object]$SafetyContext=$null
    )
    $requested=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($path in $Paths){[void]$requested.Add((ConvertTo-MorphospaceProtocolRelativePath $path))}
    $lists=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if($requested.Count-eq0){return $lists}
    $result=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('ls-files','--stage','-z','--') -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    foreach($token in @(Split-MorphospaceNulBytes $result.stdout)){
        $match=[regex]::Match($token,'^(?<mode>[0-9]{6})\s+(?<oid>[0-9a-f]{40,64})\s+(?<stage>[0-3])\t(?<path>.+)$')
        if(-not$match.Success){throw 'Damaged aggregate index entry.'}
        $path=ConvertTo-MorphospaceProtocolRelativePath $match.Groups['path'].Value
        if(-not$requested.Contains($path)){continue}
        if(-not$lists.ContainsKey($path)){$lists[$path]=[Collections.Generic.List[object]]::new()}
        $lists[$path].Add([pscustomobject][ordered]@{mode=$match.Groups['mode'].Value;oid=$match.Groups['oid'].Value;stage=[int]$match.Groups['stage'].Value})|Out-Null
    }
    return $lists
}

function Get-MorphospaceBatchedHunkEvidence {
    param(
        [string]$GitExecutable,
        [string]$RepositoryPath,
        [string]$BaseRevision,
        [object[]]$Changes,
        [string]$ExpectedGitHash='',
        [object]$SafetyContext=$null
    )
    $result=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('-c','core.safecrlf=false','-c','core.autocrlf=false','diff','--unified=0','--find-renames','--no-color','--no-ext-diff','--no-textconv',$BaseRevision,'--') -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($change in @($Changes)){
        foreach($path in @([string]$change.path,[string]$change.original_path)){
            if($path-and-not$map.ContainsKey($path)){$map[$path]=[Collections.Generic.List[object]]::new()}
        }
    }
    $lines=@((ConvertFrom-MorphospaceUtf8Bytes $result.stdout) -split "`n",0,'SimpleMatch')
    $changeIndex=-1
    for($i=0;$i-lt$lines.Count;$i++){
        if($lines[$i].StartsWith('diff --git ')){
            $changeIndex++
            if($changeIndex-ge@($Changes).Count){throw 'Unified aggregate diff has more file blocks than name-status evidence.'}
            continue
        }
        if(-not$lines[$i].StartsWith('@@ ')){continue}
        if($changeIndex-lt0-or$changeIndex-ge@($Changes).Count){throw 'Unified aggregate diff hunk is outside a file block.'}
        $start=$i;$i++
        while($i-lt$lines.Count-and-not$lines[$i].StartsWith('@@ ')-and-not$lines[$i].StartsWith('diff --git ')){$i++}
        $end=$i-1
        while($end-gt$start-and[string]$lines[$end]-ceq''){$end--}
        $i--
        $chunk=($lines[$start..$end]-join"`n")+"`n"
        $change=$Changes[$changeIndex]
        foreach($path in @([string]$change.path,[string]$change.original_path)){
            if(-not$path){continue}
            $hash=Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes($path+"`n"+$chunk))
            $map[$path].Add([pscustomobject][ordered]@{header=$lines[$start];hunk_sha256=$hash})|Out-Null
        }
    }
    if(@($Changes).Count-ne($changeIndex+1)){throw 'Unified aggregate diff file-block count differs from name-status evidence.'}
    return [pscustomobject]@{map=$map;sha256=(Get-MorphospaceSha256Bytes $result.stdout)}
}

function Assert-MorphospaceNoHiddenIndexEntries {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$ExpectedGitHash,[object]$SafetyContext=$null)
    $result=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('ls-files','-v','-z') -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    foreach($token in @(Split-MorphospaceNulBytes $result.stdout)){
        if($token.Length-lt3-or$token[1]-ne' '){throw 'Damaged Git index-visibility evidence.'}
        $tag=[char]$token[0]
        if($tag-ceq'S'-or[char]::IsLower($tag)){throw "Git skip-worktree/assume-unchanged state is not accepted: $($token.Substring(2))"}
    }
}

function Get-MorphospaceWorktreeSnapshot {
    param([string]$RepositoryPath,[string]$Path)
    $relative=ConvertTo-MorphospaceProtocolRelativePath $Path
    $absolute=[IO.Path]::GetFullPath([IO.Path]::Combine($RepositoryPath,$relative))
    Assert-MorphospaceNoReparseAncestor $RepositoryPath $absolute
    if(-not([IO.File]::Exists($absolute)-or[IO.Directory]::Exists($absolute))){return [pscustomobject]@{state=[pscustomobject][ordered]@{state='deleted';kind=$null;length=$null;sha256=$null};stream=$null}}
    $attributes=[IO.File]::GetAttributes($absolute)
    if(($attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){throw "Reparse worktree path rejected: $relative"}
    if(($attributes -band [IO.FileAttributes]::Directory)-ne0){return [pscustomobject]@{state=[pscustomobject][ordered]@{state='present';kind='directory';length=0;sha256=$null};stream=$null}}
    $stream=[IO.FileStream]::new($absolute,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$state=[pscustomobject][ordered]@{state='present';kind='file';length=[long]$stream.Length;sha256=(Get-MorphospaceStreamSha256 $stream)};$result=[pscustomobject]@{state=$state;stream=$stream};$stream=$null;return $result}finally{if($null-ne$stream){$stream.Dispose()}}
}

function Get-MorphospaceWorktreeState {
    param([string]$RepositoryPath,[string]$Path)
    $snapshot=Get-MorphospaceWorktreeSnapshot $RepositoryPath $Path
    try{return $snapshot.state}finally{if($null-ne$snapshot.stream){$snapshot.stream.Dispose()}}
}

function Get-MorphospacePathPatchEvidence {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$BaseRevision,[string]$Path,[string]$ExpectedGitHash='',[object]$SafetyContext=$null)
    $binary=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('-c','core.safecrlf=false','-c','core.autocrlf=false','diff','--binary','--full-index','--no-ext-diff','--no-textconv',$BaseRevision,'--',$Path) -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    $unified=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('-c','core.safecrlf=false','-c','core.autocrlf=false','diff','--unified=0','--no-color','--no-ext-diff','--no-textconv',$BaseRevision,'--',$Path) -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    $text=ConvertFrom-MorphospaceUtf8Bytes $unified.stdout
    $lines=@($text -split "`n",0,'SimpleMatch')
    $hunks=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $lines.Count;$i++){
        if(-not $lines[$i].StartsWith('@@ ')){continue}
        $start=$i; $i++
        while($i -lt $lines.Count -and -not $lines[$i].StartsWith('@@ ') -and -not $lines[$i].StartsWith('diff --git ')){ $i++ }
        $end=$i-1; $i--
        $chunk=($lines[$start..$end] -join "`n")+"`n"
        $utf8=[Text.UTF8Encoding]::new($false)
        [void]$hunks.Add([pscustomobject][ordered]@{header=$lines[$start];hunk_sha256=(Get-MorphospaceSha256Bytes $utf8.GetBytes($Path+"`n"+$chunk))})
    }
    return [pscustomobject][ordered]@{path=$Path;patch_sha256=(Get-MorphospaceSha256Bytes $binary.stdout);hunks=@($hunks.ToArray())}
}

function Get-MorphospaceGitCommitManifest {
    param([string]$GitExecutable,[string]$RepositoryPath,[string]$BaseRevision,[string]$HeadRevision,[string]$ExpectedGitHash='',[object]$SafetyContext=$null)
    $a=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('merge-base','--is-ancestor',$BaseRevision,$HeadRevision) -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext -AllowFailure
    if($a.exit_code -ne 0){throw 'Ownership base is not an ancestor of current HEAD.'}
    $idsResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('rev-list','--reverse','--topo-order',"$BaseRevision..$HeadRevision") -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
    $idsText=ConvertFrom-MorphospaceUtf8Bytes $idsResult.stdout
    $commits=[Collections.Generic.List[object]]::new()
    foreach($id in @($idsText -split "`n")){
        if(-not$id){continue}
        $metaResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('show','-s','--no-ext-diff','--no-textconv','--format=%H%x09%T%x09%P',$id) -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
        $meta=ConvertFrom-MorphospaceUtf8Bytes $metaResult.stdout
        $p=$meta.TrimEnd("`r","`n") -split "`t",3
        $patch=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $RepositoryPath -Arguments @('show','--format=','--binary','--full-index','--no-ext-diff','--no-textconv',$id) -ExpectedExecutableSha256 $ExpectedGitHash -SafetyContext $SafetyContext
        [void]$commits.Add([pscustomobject][ordered]@{commit=$p[0];tree=$p[1];parents=if($p.Count -eq 3 -and $p[2]){@($p[2]-split ' ')}else{@()};patch_sha256=(Get-MorphospaceSha256Bytes $patch.stdout)})
    }
    $array=@($commits.ToArray())
    return [pscustomobject][ordered]@{commits=$array;fingerprint_sha256=(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{commits=$array}))}
}

function Get-MorphospaceGitRepositoryObservation {
    param(
        [Parameter(Mandatory=$true)][string]$RepoId,
        [Parameter(Mandatory=$true)][string]$RepositoryPath,
        [Parameter(Mandatory=$true)][string]$BaseRevision,
        [Parameter(Mandatory=$true)][object[]]$AllowedPaths,
        [string]$GitExecutable=''
    )
    if(-not $GitExecutable){$GitExecutable=(Get-MorphospaceBoundExecutable git).path}
    $gitHash=Get-MorphospaceFileSha256 $GitExecutable
    $root=[IO.Path]::GetFullPath($RepositoryPath);if(-not[IO.Directory]::Exists($root)){throw "Repository root is missing: $root"}
    $rootParent=[IO.Directory]::GetParent($root);if($null-eq$rootParent){throw "Repository root cannot be a volume root: $root"};Assert-MorphospaceNoReparseAncestor $rootParent.FullName $root
    $leases=[Collections.Generic.List[IO.Stream]]::new();$leaseByPath=@{};$gitSafetyContext=$null
    try{
    $gitSafetyContext=New-MorphospaceGitSafetyContext $GitExecutable $root $gitHash
    if ($BaseRevision -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw "Base revision must be one exact lowercase full object ID." }
    $formatResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','--show-object-format') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $objectFormat=(ConvertFrom-MorphospaceUtf8Bytes $formatResult.stdout).Trim()
    $oidPattern=if($objectFormat -eq 'sha256'){'^[0-9a-f]{64}$'}elseif($objectFormat -eq 'sha1'){'^[0-9a-f]{40}$'}else{throw "Unsupported Git object format '$objectFormat'."}
    if($BaseRevision -notmatch $oidPattern){throw "Base revision does not match repository object format '$objectFormat'."}
    $verifiedBaseResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','--verify',"$BaseRevision^{commit}") -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $verifiedBase=(ConvertFrom-MorphospaceUtf8Bytes $verifiedBaseResult.stdout).Trim()
    if($verifiedBase -cne $BaseRevision){throw 'Base revision did not resolve to itself exactly.'}
    $versionResult=Invoke-MorphospaceBoundProcessBytes -Executable $GitExecutable -Arguments @('--version') -WorkingDirectory $root -ExpectedExecutableSha256 $gitHash
    $gitVersion=(ConvertFrom-MorphospaceUtf8Bytes $versionResult.stdout).Trim()
    $insideResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','--is-inside-work-tree') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $inside=ConvertFrom-MorphospaceUtf8Bytes $insideResult.stdout
    if($inside.Trim() -cne 'true'){throw "'$RepoId' is not a Git worktree."}
    $topResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','--show-toplevel') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $top=[IO.Path]::GetFullPath((ConvertFrom-MorphospaceUtf8Bytes $topResult.stdout).Trim())
    if(-not $top.Equals($root,[StringComparison]::OrdinalIgnoreCase)){throw "Mapped repository root is not Git's exact worktree root: $RepoId"}
    $headResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','HEAD') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $head=(ConvertFrom-MorphospaceUtf8Bytes $headResult.stdout).Trim()
    if($head -notmatch $oidPattern){throw 'Current HEAD is not an exact full object ID.'}
    $treeResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','HEAD^{tree}') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $tree=(ConvertFrom-MorphospaceUtf8Bytes $treeResult.stdout).Trim()
    $branchResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('symbolic-ref','--quiet','--short','HEAD') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext -AllowFailure
    if($branchResult.exit_code -ne 0){throw "'$RepoId' is detached."}
    $branch=(ConvertFrom-MorphospaceUtf8Bytes $branchResult.stdout).Trim()
    $shallowResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','--is-shallow-repository') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    if((ConvertFrom-MorphospaceUtf8Bytes $shallowResult.stdout).Trim()-cne'false'){throw "Shallow repositories are not accepted for ownership evidence: $RepoId"}
    Assert-MorphospaceNoHiddenIndexEntries $GitExecutable $root $gitHash $gitSafetyContext
    $status=Get-MorphospacePorcelainV2Status $GitExecutable $root $gitHash $gitSafetyContext
    foreach($statusRecord in @($status.records)){if([string]$statusRecord.record_type-ceq'unmerged'){throw "'$RepoId' has unmerged index state."}}
    $statusMap=@{}; foreach($r in @($status.records)){ $statusMap[[string]$r.path]=$r; if($r.original_path){$statusMap[[string]$r.original_path]=$r} }
    $changes=@(Get-MorphospaceDiffNameStatus $GitExecutable $root $BaseRevision $gitHash $gitSafetyContext)
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($c in $changes){[void]$paths.Add([string]$c.path);if($c.original_path){[void]$paths.Add([string]$c.original_path)}}
    foreach($r in @($status.records)){[void]$paths.Add([string]$r.path);if($r.original_path){[void]$paths.Add([string]$r.original_path)}}
    $sorted=Sort-MorphospaceOrdinalStrings @($paths)
    $caseFold=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($path in $sorted){if(-not $caseFold.Add($path)){throw "Case-fold path collision in '$RepoId': $path"}}
    $baseEntries=Get-MorphospaceGitTreeEntryMap $GitExecutable $root $BaseRevision $sorted $gitHash $gitSafetyContext
    $headEntries=Get-MorphospaceGitTreeEntryMap $GitExecutable $root $head $sorted $gitHash $gitSafetyContext
    $indexEntriesByPath=Get-MorphospaceGitIndexEntryMap $GitExecutable $root $sorted $gitHash $gitSafetyContext
    $hunkEvidence=Get-MorphospaceBatchedHunkEvidence $GitExecutable $root $BaseRevision $changes $gitHash $gitSafetyContext
    $wholePatch=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('-c','core.safecrlf=false','-c','core.autocrlf=false','diff','--binary','--full-index','--find-renames','--no-ext-diff','--no-textconv',$BaseRevision,'--') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $entries=[Collections.Generic.List[object]]::new()
    foreach($path in $sorted){
        $scope=if(Test-MorphospaceObservationPathAllowed $path $AllowedPaths){'allowed'}else{'outside-unit-scope'}
        $baseEntry=if($baseEntries.ContainsKey($path)){$baseEntries[$path]}else{$null}
        $headEntry=if($headEntries.ContainsKey($path)){$headEntries[$path]}else{$null}
        if(($baseEntry -and $baseEntry.kind -eq 'commit') -or ($headEntry -and $headEntry.kind -eq 'commit')){throw "Submodule changes are not accepted as unit content: $path"}
        $indexEntries=if($indexEntriesByPath.ContainsKey($path)){@($indexEntriesByPath[$path].ToArray())}else{@()}
        foreach($indexEntry in $indexEntries){if([int]$indexEntry.stage-ne0){throw "Unmerged index stages are not accepted: $path"}}
        $worktreeSnapshot=Get-MorphospaceWorktreeSnapshot $root $path;if($null-ne$worktreeSnapshot.stream){$leases.Add($worktreeSnapshot.stream);$leaseByPath[$path]=$worktreeSnapshot}
        $statusRecord=if($statusMap.ContainsKey($path)){$statusMap[$path]}else{$null}
        $patchSha=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject][ordered]@{format='content-binding-v2';path=$path;status=$statusRecord;base=$baseEntry;head=$headEntry;index=@($indexEntries);worktree=$worktreeSnapshot.state})
        $hunks=if($hunkEvidence.map.ContainsKey($path)){@($hunkEvidence.map[$path].ToArray())}else{@()}
        [void]$entries.Add([pscustomobject][ordered]@{
            path=$path;scope=$scope;attribution='unassigned'
            status=$statusRecord
            base=$baseEntry
            head=$headEntry
            index=$indexEntries
            worktree=$worktreeSnapshot.state
            patch_sha256=$patchSha;hunks=$hunks
        })
    }
    $entryArray=@($entries.ToArray())
    $commitManifest=Get-MorphospaceGitCommitManifest $GitExecutable $root $BaseRevision $head $gitHash $gitSafetyContext
    $finalHeadResult=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','HEAD') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $finalHead=(ConvertFrom-MorphospaceUtf8Bytes $finalHeadResult.stdout).Trim()
    $finalStatus=Get-MorphospacePorcelainV2Status $GitExecutable $root $gitHash $gitSafetyContext
    if($finalHead -cne $head -or $finalStatus.raw_sha256 -cne $status.raw_sha256){throw "Repository changed during observation: $RepoId"}
    foreach($entry in $entryArray){
        $finalWorktree=Get-MorphospaceWorktreeState $root ([string]$entry.path)
        if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$finalWorktree})) -cne (Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$entry.worktree}))){throw "Path changed during observation: $RepoId/$([string]$entry.path)"}
        if($leaseByPath.ContainsKey([string]$entry.path)){$lease=$leaseByPath[[string]$entry.path];if([long]$lease.stream.Length-ne[long]$entry.worktree.length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne[string]$entry.worktree.sha256){throw "Leased worktree bytes changed during observation: $RepoId/$([string]$entry.path)"}}
    }
    $finalChanges=@(Get-MorphospaceDiffNameStatus $GitExecutable $root $BaseRevision $gitHash $gitSafetyContext)
    $finalCommitManifest=Get-MorphospaceGitCommitManifest $GitExecutable $root $BaseRevision $head $gitHash $gitSafetyContext
    $finalWholePatch=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('-c','core.safecrlf=false','-c','core.autocrlf=false','diff','--binary','--full-index','--find-renames','--no-ext-diff','--no-textconv',$BaseRevision,'--') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext
    $finalHunkEvidence=Get-MorphospaceBatchedHunkEvidence $GitExecutable $root $BaseRevision $finalChanges $gitHash $gitSafetyContext
    Assert-MorphospaceNoHiddenIndexEntries $GitExecutable $root $gitHash $gitSafetyContext
    if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$finalChanges}))-cne(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{v=$changes})) -or $finalCommitManifest.fingerprint_sha256-cne$commitManifest.fingerprint_sha256 -or (Get-MorphospaceSha256Bytes $finalWholePatch.stdout)-cne(Get-MorphospaceSha256Bytes $wholePatch.stdout)-or[string]$finalHunkEvidence.sha256-cne[string]$hunkEvidence.sha256){throw "Git evidence changed during the second observation pass: $RepoId"}
    $finalHeadResult2=Invoke-MorphospaceBoundGitBytes -GitExecutable $GitExecutable -RepositoryPath $root -Arguments @('rev-parse','HEAD') -ExpectedExecutableSha256 $gitHash -SafetyContext $gitSafetyContext;$finalHead2=(ConvertFrom-MorphospaceUtf8Bytes $finalHeadResult2.stdout).Trim();$finalStatus2=Get-MorphospacePorcelainV2Status $GitExecutable $root $gitHash $gitSafetyContext
    if($finalHead2-cne$head-or$finalStatus2.raw_sha256-cne$status.raw_sha256){throw "Repository changed during the final observation boundary: $RepoId"}
    foreach($path in @($leaseByPath.Keys)){$lease=$leaseByPath[$path];$entry=$null;foreach($candidateEntry in $entryArray){if([string]$candidateEntry.path-ceq[string]$path){$entry=$candidateEntry;break}};if($null-eq$entry-or[long]$lease.stream.Length-ne[long]$entry.worktree.length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne[string]$entry.worktree.sha256){throw "Leased worktree bytes changed at the final boundary: $RepoId/$path"}}
    $finalStatus3=Get-MorphospacePorcelainV2Status $GitExecutable $root $gitHash $gitSafetyContext;if($finalStatus3.raw_sha256-cne$status.raw_sha256){throw "Repository changed after leased-byte verification: $RepoId"};Test-MorphospaceGitSafetyContext $gitSafetyContext $GitExecutable $root $gitHash
    if((Get-MorphospaceFileSha256 $GitExecutable)-cne$gitHash){throw "Bound Git executable changed during repository observation: $GitExecutable"}
    $scopeViolationCount=0;foreach($entry in $entryArray){if([string]$entry.scope-cne'allowed'){$scopeViolationCount++}}
    return [pscustomobject][ordered]@{
        repo_id=$RepoId;kind='git';git_executable_sha256=$gitHash;git_version=$gitVersion;object_format=$objectFormat;base_revision=$BaseRevision;head_revision=$head;head_tree=$tree;branch=$branch
        status_sha256=$status.raw_sha256;status_records=@($status.records);commits=@($commitManifest.commits);commit_fingerprint_sha256=$commitManifest.fingerprint_sha256
        patch_sha256=(Get-MorphospaceSha256Bytes $wholePatch.stdout);entries=$entryArray
        overlay_fingerprint_sha256=(Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$entryArray}))
        scope_violation_count=$scopeViolationCount
        attribution='unassigned'
    }
    }finally{foreach($lease in $leases){$lease.Dispose()};Close-MorphospaceGitSafetyContext $gitSafetyContext}
}

function Get-MorphospaceNonGitTreePass {
    param([string]$RepoId,[string]$Root,[object[]]$AllowedPaths,[Collections.Generic.List[object]]$Leases)
    $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$caseFold=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$rootPrefix=$Root.TrimEnd('\','/')
    foreach($raw in @($AllowedPaths)){
        $allowed=ConvertTo-MorphospaceProtocolRelativePath ([string]$raw).TrimEnd('/','\');$target=[IO.Path]::GetFullPath([IO.Path]::Combine($Root,$allowed));Assert-MorphospaceNoReparseAncestor $Root $target
        if(-not([IO.File]::Exists($target)-or[IO.Directory]::Exists($target))){throw "Non-Git surface '$RepoId/$allowed' is missing."}
        $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($target)
        while($pending.Count-gt0){
            $itemPath=$pending.Pop();$attributes=[IO.File]::GetAttributes($itemPath);if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw "Non-Git reparse point rejected: $itemPath"};$isDirectory=($attributes-band[IO.FileAttributes]::Directory)-ne0
            $rel=$itemPath.Substring($rootPrefix.Length).TrimStart('\','/').Replace('\','/');$rel=ConvertTo-MorphospaceProtocolRelativePath $rel
            if($map.ContainsKey($rel)){continue};if(-not$caseFold.Add($rel)){throw "Non-Git case-fold path collision in '$RepoId': $rel"}
            if($isDirectory){
                $map[$rel]=[pscustomobject][ordered]@{path=$rel;kind='directory';length=0;sha256=$null;attribution='unassigned'}
                $children=@([IO.Directory]::GetFileSystemEntries($itemPath));[Array]::Sort($children,[StringComparer]::Ordinal);for($i=$children.Length-1;$i-ge0;$i--){$pending.Push($children[$i])}
            }else{
                $stream=[IO.FileStream]::new($itemPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                try{$hash=Get-MorphospaceStreamSha256 $stream;$map[$rel]=[pscustomobject][ordered]@{path=$rel;kind='file';length=[long]$stream.Length;sha256=$hash;attribution='unassigned'};$Leases.Add([pscustomobject]@{path=$rel;length=[long]$stream.Length;sha256=$hash;stream=$stream});$stream=$null}finally{if($null-ne$stream){$stream.Dispose()}}
            }
        }
    }
    $arrayList=[Collections.Generic.List[object]]::new();foreach($key in @(Sort-MorphospaceOrdinalStrings @($map.Keys))){$arrayList.Add($map[$key])};return @($arrayList.ToArray())
}

function Get-MorphospaceNonGitTreeObservation {
    param([string]$RepoId,[string]$RootPath,[object[]]$AllowedPaths)
    $root=[IO.Path]::GetFullPath($RootPath);if(-not[IO.Directory]::Exists($root)){throw "Non-Git root is missing: $root"};$rootParent=[IO.Directory]::GetParent($root);if($null-eq$rootParent){throw "Non-Git root cannot be a volume root: $root"};Assert-MorphospaceNoReparseAncestor $rootParent.FullName $root
    $leases=[Collections.Generic.List[object]]::new()
    try{
        $first=@(Get-MorphospaceNonGitTreePass $RepoId $root $AllowedPaths $leases);$second=@(Get-MorphospaceNonGitTreePass $RepoId $root $AllowedPaths $leases)
        $firstFingerprint=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$first});$secondFingerprint=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$second})
        if($firstFingerprint-cne$secondFingerprint){throw "Non-Git tree changed across the two leased observation passes: $RepoId"}
        foreach($lease in $leases){if([long]$lease.stream.Length-ne[long]$lease.length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne[string]$lease.sha256){throw "Non-Git leased bytes changed during observation: $RepoId/$([string]$lease.path)"}}
        $boundary=@(Get-MorphospaceNonGitTreePass $RepoId $root $AllowedPaths $leases);$boundaryFingerprint=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$boundary});if($boundaryFingerprint-cne$secondFingerprint){throw "Non-Git tree changed at the final observation boundary: $RepoId"}
        foreach($lease in $leases){if([long]$lease.stream.Length-ne[long]$lease.length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne[string]$lease.sha256){throw "Non-Git leased bytes changed at the final boundary: $RepoId/$([string]$lease.path)"}}
        return [pscustomobject][ordered]@{repo_id=$RepoId;kind='non-git';entries=$boundary;tree_fingerprint_sha256=$boundaryFingerprint;attribution='unassigned'}
    }finally{foreach($lease in $leases){$lease.stream.Dispose()}}
}

function Get-MorphospaceRepositoryAliasMap {
    param([hashtable]$RepositoryMap)
    $aliases=@{}
    foreach($repoId in @($RepositoryMap.Keys)){
        $entry=$RepositoryMap[$repoId]
        foreach($alias in @($repoId)+@($entry.aliases)){
            $key=[string]$alias
            if(-not $key){continue}
            if($aliases.ContainsKey($key)){throw "Repository alias '$key' is ambiguous."}
            $aliases[$key]=$repoId
        }
    }
    return $aliases
}

function Resolve-MorphospaceInstructionSurface {
    param([object]$Surface,[hashtable]$RepositoryMap)
    $declared=[string]$Surface.path;$repoId=$null;$relative=$null
    if($declared -match '^<(?<alias>[a-z0-9-]+)>[\\/](?<path>.+)$'){
        $aliases=Get-MorphospaceRepositoryAliasMap $RepositoryMap;$alias=$Matches['alias']
        if(-not $aliases.ContainsKey($alias)){throw "Instruction alias '<$alias>' is not in the bound repository map."}
        $repoId=[string]$aliases[$alias];$relative=ConvertTo-MorphospaceProtocolRelativePath $Matches['path']
    } elseif([IO.Path]::IsPathRooted($declared)){
        $candidate=[IO.Path]::GetFullPath($declared);$matches=@()
        foreach($id in @($RepositoryMap.Keys)){$root=[IO.Path]::GetFullPath([string]$RepositoryMap[$id].path).TrimEnd('\','/');if($candidate.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){$matches+=@([pscustomobject]@{id=$id;root=$root})}}
        if($matches.Count-ne 1){throw "Rooted instruction surface '$declared' must resolve to one mapped owner."}
        $repoId=[string]$matches[0].id;$relative=$candidate.Substring($matches[0].root.Length).TrimStart('\','/').Replace('\','/');$relative=ConvertTo-MorphospaceProtocolRelativePath $relative
    } else { throw "Instruction surface '$declared' must use a bound <alias>/path or one rooted mapped path." }
    $root=[IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path);$absolute=[IO.Path]::GetFullPath([IO.Path]::Combine($root,$relative));Assert-MorphospaceNoReparseAncestor $root $absolute
    if(-not[IO.File]::Exists($absolute)){throw "Instruction surface is missing: $declared"}
    return [pscustomobject][ordered]@{surface_kind=[string]$Surface.surface_kind;path=$declared.Replace('\','/');repo_id=$repoId;relative_path=$relative;owner=[string]$Surface.owner;action=[string]$Surface.action;status=[string]$Surface.status;absolute_path=$absolute}
}

function Get-MorphospaceInstructionSurfacePass {
    param([object]$Unit,[hashtable]$RepositoryMap,[Collections.Generic.List[object]]$Leases)
    $declaredPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$absolutePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$identities=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$entries=[Collections.Generic.List[object]]::new()
    foreach($surface in @($Unit.instruction_surfaces)){
        if([string]$surface.status-cne'complete'){throw "Instruction incomplete: $([string]$surface.path)"};$entry=Resolve-MorphospaceInstructionSurface $surface $RepositoryMap;$declared=[string]$entry.path;$absolute=[IO.Path]::GetFullPath([string]$entry.absolute_path);$identity="$([string]$entry.repo_id)/$([string]$entry.relative_path)"
        if(-not$declaredPaths.Add($declared)){throw "Instruction surface declared-path collision: $declared"};if(-not$absolutePaths.Add($absolute)-or-not$identities.Add($identity)){throw "Instruction surface identity collision: $identity"}
        foreach($prior in @($entries)){if($absolute.StartsWith(([string]$prior.absolute_path).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-or([string]$prior.absolute_path).StartsWith($absolute.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Instruction surface overlap is not accepted: $absolute"}}
        $stream=[IO.FileStream]::new($absolute,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{if($stream.Length-gt16777216){throw "Instruction surface exceeds 16 MiB: $declared"};$hash=Get-MorphospaceStreamSha256 $stream;$Leases.Add([pscustomobject]@{path=$absolute;length=[long]$stream.Length;sha256=$hash;stream=$stream});$stream=$null;$entries.Add([pscustomobject][ordered]@{surface_kind=[string]$entry.surface_kind;path=$declared;repo_id=[string]$entry.repo_id;relative_path=[string]$entry.relative_path;owner=[string]$entry.owner;action=[string]$entry.action;status=[string]$entry.status;sha256=$hash;identity=$identity;absolute_path=$absolute})}finally{if($null-ne$stream){$stream.Dispose()}}
    }
    $array=@($entries.ToArray());[Array]::Sort($array,[Comparison[object]]{param($left,$right)[StringComparer]::Ordinal.Compare([string]$left.identity,[string]$right.identity)});return $array
}

function ConvertTo-MorphospacePublicInstructionEntries {
    param([object[]]$Entries)
    $result=[Collections.Generic.List[object]]::new();foreach($entry in $Entries){$result.Add([pscustomobject][ordered]@{surface_kind=[string]$entry.surface_kind;path=[string]$entry.path;repo_id=[string]$entry.repo_id;relative_path=[string]$entry.relative_path;owner=[string]$entry.owner;action=[string]$entry.action;status=[string]$entry.status;sha256=[string]$entry.sha256})};return @($result.ToArray())
}

function Get-MorphospaceInstructionObservation {
    param([object]$Unit,[hashtable]$RepositoryMap)
    if([string]$Unit.instruction_impact-ceq'none'){if(@($Unit.instruction_surfaces).Count-ne0){throw 'instruction_impact none must have an empty instruction surface set.'};return @()}
    if(@($Unit.instruction_surfaces).Count-eq0){throw 'Instruction impact requires at least one explicit surface.'}
    $leases=[Collections.Generic.List[object]]::new()
    try{
        $first=@(Get-MorphospaceInstructionSurfacePass $Unit $RepositoryMap $leases);$second=@(Get-MorphospaceInstructionSurfacePass $Unit $RepositoryMap $leases);$firstPublic=@(ConvertTo-MorphospacePublicInstructionEntries $first);$secondPublic=@(ConvertTo-MorphospacePublicInstructionEntries $second)
        $expected=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$firstPublic});$actual=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$secondPublic});if($expected-cne$actual){throw 'Instruction surface set/hash changed across leased passes.'}
        foreach($lease in $leases){if([long]$lease.stream.Length-ne[long]$lease.length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne[string]$lease.sha256){throw "Instruction surface changed under lease: $([string]$lease.path)"}}
        $boundary=@(Get-MorphospaceInstructionSurfacePass $Unit $RepositoryMap $leases);$boundaryPublic=@(ConvertTo-MorphospacePublicInstructionEntries $boundary);if((Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{entries=$boundaryPublic}))-cne$expected){throw 'Instruction surface set/hash changed at the final boundary.'}
        foreach($lease in $leases){if([long]$lease.stream.Length-ne[long]$lease.length-or(Get-MorphospaceStreamSha256 $lease.stream)-cne[string]$lease.sha256){throw "Instruction surface changed at final boundary: $([string]$lease.path)"}}
        return $boundaryPublic
    }finally{foreach($lease in $leases){$lease.stream.Dispose()}}
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Sort-MorphospaceOrdinalStrings,Get-MorphospaceBoundExecutable,Invoke-MorphospaceBoundProcessBytes,Test-MorphospaceObservationPathAllowed,Get-MorphospaceGitRepositoryObservation,Get-MorphospaceNonGitTreeObservation,Get-MorphospaceInstructionObservation
