Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationReceipt.psm1') -Force

$script:SourceOnlyInputGit = $null

if ($IsWindows -and -not ('MorphospaceSourceOnlyInputFileIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class MorphospaceSourceOnlyInputFileIdentity {
 [StructLayout(LayoutKind.Sequential)] struct ID128 {[MarshalAs(UnmanagedType.ByValArray,SizeConst=16)] public byte[] v;}
 [StructLayout(LayoutKind.Sequential)] struct INFO {public UInt64 volume; public ID128 id;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr q,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h,int c,out INFO i,uint z);
 public static string Directory(string p){using(var h=CreateFileW(p,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)){if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error()); INFO i;if(!GetFileInformationByHandleEx(h,18,out i,(uint)Marshal.SizeOf<INFO>()))throw new Win32Exception(Marshal.GetLastWin32Error());return i.volume.ToString("x16")+":"+BitConverter.ToString(i.id.v).Replace("-","").ToLowerInvariant();}}
}
'@
}

function Get-SourceOnlyInputGit {
    if ($null -eq $script:SourceOnlyInputGit) {
        $script:SourceOnlyInputGit = Get-MorphospaceBoundExecutable -Name 'git'
    }
    return $script:SourceOnlyInputGit
}

function Invoke-SourceOnlyInputGit {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )
    $git = Get-SourceOnlyInputGit
    $safe = @(
        '--no-optional-locks', '--no-replace-objects', '--literal-pathspecs',
        '-c', 'core.quotepath=false', '-c', 'color.ui=false', '-c', 'core.fsmonitor=false',
        '-c', 'diff.external=', '-c', 'core.hooksPath=NUL', '-c', 'credential.interactive=never',
        '-C', $Repository
    ) + $Arguments
    $result = Invoke-MorphospaceBoundProcessBytes -Executable $git.path -ExpectedExecutableSha256 $git.sha256 `
        -Arguments $safe -WorkingDirectory $Repository -TimeoutSeconds $TimeoutSeconds -MaxOutputBytes 1048576 -AllowFailure:$AllowFailure
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($result.stdout)
    $lines = if ($text.Length -eq 0) { @() } else { @($text.TrimEnd("`r", "`n").Split("`n") | ForEach-Object { $_.TrimEnd("`r") }) }
    return [pscustomobject]@{ exit_code = [int]$result.exit_code; lines = @($lines); stdout = [byte[]]$result.stdout }
}

function Get-SourceOnlyInputGitValue {
    param([string]$Repository, [string[]]$Arguments, [string]$Label)
    $result = Invoke-SourceOnlyInputGit -Repository $Repository -Arguments $Arguments
    if (@($result.lines).Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$result.lines[0])) {
        throw "$Label did not return exactly one value."
    }
    return ([string]$result.lines[0]).Trim()
}

function Get-SourceOnlyInputLocalConfigCount {
    param([string]$Repository, [string]$Name)
    $result = Invoke-SourceOnlyInputGit -Repository $Repository -Arguments @('config', '--local', '--get-all', $Name) -AllowFailure
    if ($result.exit_code -notin @(0, 1)) { throw "Local Git configuration observation failed for '$Name'." }
    return @($result.lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

function Get-SourceOnlyInputLocalConfigState {
    param([string]$Repository, [string]$Name)
    $result = Invoke-SourceOnlyInputGit -Repository $Repository -Arguments @('config', '--local', '--get', $Name) -AllowFailure
    if ($result.exit_code -eq 1) { return 'unset' }
    if ($result.exit_code -ne 0 -or @($result.lines).Count -ne 1) { throw "Local Git configuration observation failed for '$Name'." }
    $value = ([string]$result.lines[0]).Trim().ToLowerInvariant()
    if ($value -notin @('true', 'false', 'input', 'auto', 'native', 'lf', 'crlf')) { return 'configured' }
    return $value
}

function Get-SourceOnlyInputPhysicalIdentity {
    param([string]$Path, [string]$Label)
    if (-not $IsWindows) { throw "$Label physical identity is unavailable on this host." }
    try { return [MorphospaceSourceOnlyInputFileIdentity]::Directory([IO.Path]::GetFullPath($Path)) }
    catch { throw "$Label physical identity observation failed: $($_.Exception.Message)" }
}

function Get-SourceOnlyInputCommonDirectory {
    param([string]$Repository, [string]$Label)
    return (Get-SourceOnlyInputGitValue $Repository @('rev-parse', '--path-format=absolute', '--git-common-dir') $Label).TrimEnd('\', '/')
}

function Get-SourceOnlyInputSortedPaths {
    param([AllowEmptyCollection()][object[]]$Paths, [string]$Label)
    [string[]]$values = @($Paths | ForEach-Object {
        $value = ([string]$_).Replace('\', '/')
        if ($value -cnotmatch '^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$') { throw "$Label contains noncanonical path '$value'." }
        $value
    })
    [Array]::Sort($values, [StringComparer]::Ordinal)
    for ($i = 1; $i -lt $values.Count; $i++) {
        if ($values[$i - 1] -ceq $values[$i]) { throw "$Label repeats path '$($values[$i])'." }
    }
    return @($values)
}

function Test-SourceOnlyInputPathAllowed {
    param([string]$Path, [AllowEmptyCollection()][object[]]$AllowedPaths)
    foreach ($raw in @($AllowedPaths)) {
        $allowed = ([string]$raw).Replace('\', '/').TrimEnd('/')
        if ($Path.Equals($allowed, [StringComparison]::Ordinal) -or $Path.StartsWith($allowed + '/', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Assert-SourceOnlyInputSetEqual {
    param([AllowEmptyCollection()][object[]]$Expected, [AllowEmptyCollection()][object[]]$Actual, [string]$Label)
    $left = @(Get-SourceOnlyInputSortedPaths -Paths $Expected -Label "$Label expected")
    $right = @(Get-SourceOnlyInputSortedPaths -Paths $Actual -Label "$Label actual")
    if (($left -join "`n") -cne ($right -join "`n")) { throw "$Label does not match exactly." }
}

function Resolve-SourceOnlyInputPath {
    param([string]$Path, [ValidateSet('Leaf', 'Container')][string]$Kind, [string]$Label)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType $Kind)) { throw "$Label is not an existing $($Kind.ToLowerInvariant())." }
    return [IO.Path]::GetFullPath($resolved.Path).TrimEnd('\', '/')
}

function Write-SourceOnlyInputDocument {
    param([object]$Document, [string]$OutPath)
    if ([string]::IsNullOrWhiteSpace($OutPath)) { throw 'A create-new output path is required.' }
    $full = [IO.Path]::GetFullPath($OutPath)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output parent does not exist: $parent" }
    $bytes = ConvertTo-MorphospaceProtocolJsonBytes -Value $Document
    $stream = $null
    try {
        $stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return [pscustomobject][ordered]@{ path = $full; sha256 = Get-MorphospaceFileSha256 -Path $full; document = $Document }
}

function Assert-SourceOnlyInputRemoteUrl {
    param([string]$RemoteUrl, [string]$RepoId)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl) -or $RemoteUrl.Contains("`r") -or $RemoteUrl.Contains("`n")) { throw "Source repository '$RepoId' has an invalid remote URL." }
    if ([IO.Path]::IsPathRooted($RemoteUrl)) {
        if (-not (Test-Path -LiteralPath $RemoteUrl -PathType Container)) { throw "Source repository '$RepoId' local fixture remote does not exist." }
        return
    }
    if ($RemoteUrl -cmatch '^(?<user>[A-Za-z0-9._-]+)@(?<host>[A-Za-z0-9.-]+):(?<path>[A-Za-z0-9._/-]+)$') { return }
    $uri = $null
    if (-not [Uri]::TryCreate($RemoteUrl, [UriKind]::Absolute, [ref]$uri)) { throw "Source repository '$RepoId' remote URL syntax is unsupported." }
    if ($uri.Scheme -ceq 'https') {
        if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment) -or [string]::IsNullOrEmpty($uri.Host)) { throw "Source repository '$RepoId' remote URL contains credential-bearing or non-identity components." }
        return
    }
    if ($uri.Scheme -ceq 'ssh') {
        if ((-not [string]::IsNullOrEmpty($uri.UserInfo) -and $uri.UserInfo -cne 'git') -or $uri.UserInfo.Contains(':') -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment) -or [string]::IsNullOrEmpty($uri.Host)) { throw "Source repository '$RepoId' SSH remote URL contains credential-bearing or non-identity components." }
        return
    }
    throw "Source repository '$RepoId' remote URL scheme is unsupported by readiness."
}

function Get-SourceOnlyInputRemoteReadback {
    param([string]$Repository, [string]$RemoteUrl, [string]$TargetBranch)
    try {
        $result = Invoke-SourceOnlyInputGit -Repository $Repository -Arguments @('ls-remote', '--refs', $RemoteUrl, "refs/heads/$TargetBranch") -AllowFailure -TimeoutSeconds 30
    } catch {
        if ($_.Exception.Message -match '(?i)timed?\s*out|timeout|exceeded.{0,40}seconds') { return [pscustomobject]@{ status = 'unavailable'; revision = $null } }
        throw
    }
    if ($result.exit_code -ne 0) { return [pscustomobject]@{ status = 'unavailable'; revision = $null } }
    $rows = @($result.lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($rows.Count -ne 1 -or [string]$rows[0] -cnotmatch '^([0-9a-f]{40})\trefs/heads/(.+)$' -or $Matches[2] -cne $TargetBranch) {
        return [pscustomobject]@{ status = 'unavailable'; revision = $null }
    }
    return [pscustomobject]@{ status = 'observed'; revision = $Matches[1].ToLowerInvariant() }
}

function Get-SourceOnlyInputContext {
    param([string]$WorkspaceRoot, [string]$UnitId, [string]$RepoMapPath)
    $workspace = Resolve-SourceOnlyInputPath $WorkspaceRoot Container 'Workspace root'
    $mapPath = Resolve-SourceOnlyInputPath $RepoMapPath Leaf 'Repository map'
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $mapRaw = Get-Content -Raw -LiteralPath $mapPath
    if (-not (Test-Json -Json $mapRaw -SchemaFile (Join-Path $repoRoot 'schemas\repository-map.schema.json'))) { throw 'Repository map does not satisfy its schema.' }
    $map = Read-MorphospaceProtocolJson -Path $mapPath
    $projectPath = Join-Path $workspace 'project.spec.json'
    $statePath = Join-Path $workspace 'workspace.state.json'
    $unitPath = Join-Path $workspace "iteration-units/$UnitId.json"
    $eventsPath = Join-Path $workspace 'iteration-events.jsonl'
    foreach ($path in @($projectPath, $statePath, $unitPath, $eventsPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required workspace input does not exist: $path" } }
    $project = Read-MorphospaceProtocolJson $projectPath
    $state = Read-MorphospaceProtocolJson $statePath
    $unit = Read-MorphospaceProtocolJson $unitPath
    if ([string]$project.project_id -cne [string]$state.project_id -or [string]$unit.project_id -cne [string]$project.project_id -or [string]$unit.unit_id -cne $UnitId) { throw 'Project, state, and unit identities do not agree.' }
    $eventLines = @(Get-Content -LiteralPath $eventsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($eventLines.Count -eq 0) { throw 'Iteration event ledger is empty.' }
    $tail = $eventLines[-1] | ConvertFrom-Json -Depth 64 -DateKind String
    if ([string]$tail.event_id -cne [string]$state.last_event_id) { throw 'Workspace state does not match the event-ledger tail.' }
    return [pscustomobject]@{ repo_root = $repoRoot; workspace = $workspace; map = $map; project = $project; project_path = $projectPath; state = $state; state_path = $statePath; unit = $unit; unit_path = $unitPath; events_path = $eventsPath; tail = $tail }
}

function Get-SourceOnlyPublicationAnalysis {
    param(
        [string]$WorkspaceRoot, [string]$UnitId, [string]$RepoMapPath, [string]$PublicationId,
        [ValidateSet('fast-forward', 'provider-merge')][string]$PublicationMode,
        [string]$Remote, [string]$TargetBranch
    )
    $context = Get-SourceOnlyInputContext $WorkspaceRoot $UnitId $RepoMapPath
    $reasons = [Collections.Generic.List[string]]::new()
    $unavailable = [Collections.Generic.List[string]]::new()
    if ([string]$context.unit.push_checkpoint -cne 'integration-batch') { $reasons.Add('checkpoint-not-integration-batch') }
    $planningRows = @($context.map.repositories | Where-Object { [string]$_.role -ceq 'planning' })
    if ($planningRows.Count -ne 1) { throw 'Repository map must contain exactly one planning owner.' }
    $planningRoot = Resolve-SourceOnlyInputPath ([string]$planningRows[0].path) Container 'Planning repository'
    $top = [IO.Path]::GetFullPath((Get-SourceOnlyInputGitValue $planningRoot @('rev-parse', '--show-toplevel') 'Planning root')).TrimEnd('\', '/')
    $workspacePrefix = $top + [IO.Path]::DirectorySeparatorChar
    if (-not ($context.workspace.Equals($top, [StringComparison]::OrdinalIgnoreCase) -or $context.workspace.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase))) { throw 'Workspace is not contained by the planning owner.' }
    $planningStatus = Invoke-SourceOnlyInputGit $planningRoot @('status', '--porcelain=v1', '--untracked-files=all')
    if (@($planningStatus.lines).Count -ne 0) { $reasons.Add('planning-owner-dirty') }
    $planningRemotes = Invoke-SourceOnlyInputGit $planningRoot @('remote')
    if (@($planningRemotes.lines).Count -ne 0) { $reasons.Add('planning-owner-has-remote') }
    $planning = [pscustomobject][ordered]@{
        repo_id = [string]$planningRows[0].repo_id
        branch = Get-SourceOnlyInputGitValue $planningRoot @('branch', '--show-current') 'Planning branch'
        head = (Get-SourceOnlyInputGitValue $planningRoot @('rev-parse', 'HEAD') 'Planning HEAD').ToLowerInvariant()
        tree = (Get-SourceOnlyInputGitValue $planningRoot @('rev-parse', 'HEAD^{tree}') 'Planning tree').ToLowerInvariant()
        remote_count = @($planningRemotes.lines).Count
    }
    $mapSources = @($context.map.repositories | Where-Object { [string]$_.role -ceq 'source' })
    $allowed = @($context.unit.allowed_repositories)
    $readOnlyIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($context.unit.PSObject.Properties.Name -contains 'read_only_dependencies') { foreach ($item in @($context.unit.read_only_dependencies)) { [void]$readOnlyIds.Add([string]$item.repo_id) } }
    foreach ($projectSource in @($context.project.repositories)) {
        $projectRepoId = [string]$projectSource.repo_id
        if (@($allowed | Where-Object { [string]$_.repo_id -ceq $projectRepoId }).Count -eq 0 -and -not $readOnlyIds.Contains($projectRepoId)) { $reasons.Add("project-source-not-declared:$projectRepoId") }
    }
    $planningIdentities = @(
        (Get-SourceOnlyInputPhysicalIdentity $planningRoot 'Planning repository')
        (Get-SourceOnlyInputPhysicalIdentity (Get-SourceOnlyInputCommonDirectory $planningRoot 'Planning Git common directory') 'Planning Git common directory')
    )
    $sourceIdentityOwners = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $rows = [Collections.Generic.List[object]]::new()
    $reportRows = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $allowed.Count; $i++) {
        $scope = $allowed[$i]
        $repoId = [string]$scope.repo_id
        $mapped = @($mapSources | Where-Object { [string]$_.repo_id -ceq $repoId })
        $projectRows = @($context.project.repositories | Where-Object { [string]$_.repo_id -ceq $repoId })
        if ($mapped.Count -ne 1 -or $projectRows.Count -ne 1) { $reasons.Add("allowed-source-shape-unsupported:$repoId"); continue }
        $repository = Resolve-SourceOnlyInputPath ([string]$mapped[0].path) Container "Source repository '$repoId'"
        foreach ($identity in @(
            (Get-SourceOnlyInputPhysicalIdentity $repository "Source repository '$repoId'")
            (Get-SourceOnlyInputPhysicalIdentity (Get-SourceOnlyInputCommonDirectory $repository "Source '$repoId' Git common directory") "Source '$repoId' Git common directory")
        )) {
            if ($planningIdentities -contains $identity) { $reasons.Add("source-planning-physical-alias:$repoId") }
            if ($sourceIdentityOwners.ContainsKey($identity) -and [string]$sourceIdentityOwners[$identity] -cne $repoId) { $reasons.Add("source-physical-alias:$repoId") }
            elseif (-not $sourceIdentityOwners.ContainsKey($identity)) { $sourceIdentityOwners.Add($identity, $repoId) }
        }
        $status = Invoke-SourceOnlyInputGit $repository @('status', '--porcelain=v1', '--untracked-files=all')
        if (@($status.lines).Count -ne 0) { $reasons.Add("source-dirty:$repoId") }
        $branch = Get-SourceOnlyInputGitValue $repository @('branch', '--show-current') "Source '$repoId' branch"
        $upstream = Get-SourceOnlyInputGitValue $repository @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') "Source '$repoId' upstream"
        if ($upstream -cne "$Remote/$TargetBranch") { $reasons.Add("upstream-target-mismatch:$repoId") }
        $remoteUrl = Get-SourceOnlyInputGitValue $repository @('remote', 'get-url', $Remote) "Source '$repoId' remote URL"
        Assert-SourceOnlyInputRemoteUrl $remoteUrl $repoId
        $candidate = (Get-SourceOnlyInputGitValue $repository @('rev-parse', 'HEAD') "Source '$repoId' HEAD").ToLowerInvariant()
        $candidateTree = (Get-SourceOnlyInputGitValue $repository @('rev-parse', 'HEAD^{tree}') "Source '$repoId' tree").ToLowerInvariant()
        $remoteReadback = Get-SourceOnlyInputRemoteReadback $repository $remoteUrl $TargetBranch
        if ($remoteReadback.status -cne 'observed') {
            $unavailable.Add("remote-readback-unavailable:$repoId")
            $reportRows.Add([pscustomobject][ordered]@{ dependency_ordinal = $i + 1; repo_id = $repoId; status = 'unavailable'; allowed_path_count = @($scope.allowed_paths).Count })
            continue
        }
        $old = [string]$remoteReadback.revision
        if ($old -ceq $candidate) { $reasons.Add("no-publication-delta:$repoId") }
        $ancestor = Invoke-SourceOnlyInputGit $repository @('merge-base', '--is-ancestor', $old, $candidate) -AllowFailure
        if ($ancestor.exit_code -ne 0) { $reasons.Add("remote-not-ancestor:$repoId") }
        $oldTree = (Get-SourceOnlyInputGitValue $repository @('rev-parse', "$old^{tree}") "Source '$repoId' old tree").ToLowerInvariant()
        $changed = @(Get-SourceOnlyInputSortedPaths @((Invoke-SourceOnlyInputGit $repository @('diff', '--name-only', '--no-renames', "$old..$candidate", '--')).lines | Where-Object { $_ }) "Source '$repoId' changed paths")
        if ($changed.Count -eq 0) { $reasons.Add("no-publication-delta:$repoId") }
        foreach ($path in $changed) { if (-not (Test-SourceOnlyInputPathAllowed $path @($projectRows[0].allowed_paths))) { $reasons.Add("path-outside-project-scope:$repoId") } }
        $attributes = Invoke-SourceOnlyInputGit $repository (@('check-attr', '-z', '--all', '--') + $changed) -AllowFailure
        if ($attributes.exit_code -ne 0) { $reasons.Add("attribute-observation-failed:$repoId") }
        $row = [pscustomobject][ordered]@{
            dependency_ordinal = $i + 1; repo_id = $repoId; repository = $repository; publication_mode = $PublicationMode
            candidate_branch = $branch; target_branch = $TargetBranch; upstream = $upstream; remote = $Remote; remote_url = $remoteUrl
            old_revision = $old; old_tree = $oldTree; candidate_revision = $candidate; candidate_tree = $candidateTree; changed_paths = @($changed)
            project_allowed_paths = @($projectRows[0].allowed_paths); unit_allowed_paths = @($scope.allowed_paths)
        }
        $rows.Add($row)
        $reportRows.Add([pscustomobject][ordered]@{
            dependency_ordinal = $i + 1; repo_id = $repoId; status = $(if ($old -ceq $candidate) { 'unsupported' } else { 'candidate-observed' })
            candidate_branch = $branch; target_branch = $TargetBranch; upstream = $upstream; old_revision = $old; candidate_revision = $candidate
            changed_paths = @($changed); allowed_path_count = @($scope.allowed_paths).Count
            remote_url_sha256 = Get-MorphospaceSha256Bytes ([Text.UTF8Encoding]::new($false).GetBytes($remoteUrl))
            isolated_git = [pscustomobject][ordered]@{
                credential_helper_count = Get-SourceOnlyInputLocalConfigCount $repository 'credential.helper'
                core_autocrlf = Get-SourceOnlyInputLocalConfigState $repository 'core.autocrlf'
                core_eol = Get-SourceOnlyInputLocalConfigState $repository 'core.eol'
                attributes_sha256 = Get-MorphospaceSha256Bytes ([byte[]]$attributes.stdout)
            }
        })
    }
    [string[]]$reasonArray = @($reasons.ToArray() | Sort-Object -Unique)
    [string[]]$unavailableArray = @($unavailable.ToArray() | Sort-Object -Unique)
    $statusValue = if ($unavailableArray.Count -gt 0) { 'unavailable' } elseif ($reasonArray.Count -gt 0) { 'unsupported' } else { 'supported' }
    $git = Get-SourceOnlyInputGit
    $version = Get-SourceOnlyInputGitValue $planningRoot @('--version') 'Git version'
    $report = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.source_only_publication_readiness.v1'
        publication_id = $PublicationId; project_id = [string]$context.project.project_id; unit_id = $UnitId; readiness_scope = 'layout-and-source-shape'; status = $statusValue
        reason_codes = @($reasonArray + $unavailableArray)
        environment = [pscustomobject][ordered]@{ git_executable_sha256 = [string]$git.sha256; git_version = $version; isolated_configuration = $true; credential_values_recorded = $false }
        planning_owner = $planning
        source_repositories = @($reportRows.ToArray())
        resume = [pscustomobject][ordered]@{ action = 'rerun-readiness-with-same-publication-id'; bounded_remote_retry = ($unavailableArray.Count -gt 0); source_or_evidence_repair_required = ($reasonArray.Count -gt 0) }
        preservation = [pscustomobject][ordered]@{ git_mutation_performed = $false; device_mutation_performed = $false; acceptance_inferred = $false; execution_inferred = $false; credentials_recorded = $false }
    }
    return [pscustomobject]@{ context = $context; planning = $planning; planning_root = $planningRoot; rows = @($rows.ToArray()); report = $report }
}

function Get-MorphospaceSourceOnlyPublicationReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$RepoMapPath, [Parameter(Mandatory = $true)][string]$PublicationId,
        [ValidateSet('fast-forward', 'provider-merge')][string]$PublicationMode = 'provider-merge',
        [string]$Remote = 'origin', [string]$TargetBranch = 'main', [string]$OutPath = ''
    )
    if ($PublicationId -cnotmatch '^[a-z0-9][a-z0-9-]{1,91}$') { throw 'Publication ID is invalid.' }
    $analysis = Get-SourceOnlyPublicationAnalysis $WorkspaceRoot $UnitId $RepoMapPath $PublicationId $PublicationMode $Remote $TargetBranch
    if ($OutPath) { return Write-SourceOnlyInputDocument $analysis.report $OutPath }
    return $analysis.report
}

function New-MorphospaceSourceOnlyPublicationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot, [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$RepoMapPath, [Parameter(Mandatory = $true)][string]$PublicationId,
        [ValidateSet('fast-forward', 'provider-merge')][string]$PublicationMode = 'provider-merge',
        [string]$Remote = 'origin', [string]$TargetBranch = 'main', [Parameter(Mandatory = $true)][string]$OutPath
    )
    $analysis = Get-SourceOnlyPublicationAnalysis $WorkspaceRoot $UnitId $RepoMapPath $PublicationId $PublicationMode $Remote $TargetBranch
    if ([string]$analysis.report.status -cne 'supported') { throw "Source-only publication readiness is '$($analysis.report.status)': $(@($analysis.report.reason_codes) -join ', ')." }
    $c = $analysis.context
    if ([string]$c.unit.status -cne 'accepted' -or $null -ne $c.state.current_unit -or $null -ne $c.state.pending_push_bundle) { throw 'Plan generation requires the exact accepted idle trigger with no pending publication bundle.' }
    $acceptanceEvent = $c.tail
    if ([string]$acceptanceEvent.unit_id -cne $UnitId -or [string]$acceptanceEvent.event_id -cnotmatch ('^' + [regex]::Escape($UnitId) + '-accepted-[0-9]{4,}$') -or @($acceptanceEvent.receipts).Count -ne 1) { throw 'Event-ledger tail is not the exact acceptance transition for the trigger unit.' }
    $receiptRelative = [string]$acceptanceEvent.receipts[0]
    if ($receiptRelative -cne [string]$c.state.last_accepted_receipt -or $receiptRelative -cne [string]$c.state.validation_checkpoint.receipt) { throw 'Accepted state does not bind the tail validation receipt.' }
    $receiptPath = Resolve-MorphospaceWorkspacePath $c.workspace $receiptRelative -RequireLeaf
    $receipt = Assert-MorphospaceValidationReceiptStructure -ReceiptPath $receiptPath -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1'
    if ([string]$receipt.project_id -cne [string]$c.project.project_id -or [string]$receipt.unit_id -cne $UnitId -or [string]$receipt.result -cne 'pass') { throw 'Accepted validation receipt is not a passing receipt for this project and unit.' }
    foreach ($artifact in @($receipt.artifacts)) {
        $artifactPath = if ([IO.Path]::IsPathRooted([string]$artifact.path)) { [IO.Path]::GetFullPath([string]$artifact.path) } else { [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $receiptPath) ([string]$artifact.path))) }
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or (Get-MorphospaceFileSha256 $artifactPath) -cne ([string]$artifact.sha256).ToLowerInvariant()) { throw "Accepted validation artifact '$([string]$artifact.artifact_id)' drifted." }
    }
    $transactionId = "$([string]$acceptanceEvent.event_id)-transition"
    [void](Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $c.workspace -TransactionId $transactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$UnitId.json" -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail)
    $planRows = [Collections.Generic.List[object]]::new()
    foreach ($row in @($analysis.rows)) {
        $validatedRevision = @($receipt.repository_revisions | Where-Object { [string]$_.repo_id -ceq [string]$row.repo_id })
        if ($validatedRevision.Count -ne 1 -or [string]$validatedRevision[0].head_revision -cne [string]$row.candidate_revision -or [string]$validatedRevision[0].branch -cne [string]$row.candidate_branch) { throw "Accepted validation revision differs for '$([string]$row.repo_id)'." }
        $triggerPaths = @(Get-SourceOnlyInputSortedPaths @($receipt.changed_paths | Where-Object { [string]$_.repo_id -ceq [string]$row.repo_id } | ForEach-Object { [string]$_.path }) "Source '$([string]$row.repo_id)' trigger paths")
        foreach ($path in $triggerPaths) { if (-not (Test-SourceOnlyInputPathAllowed $path @($row.unit_allowed_paths))) { throw "Trigger path '$([string]$row.repo_id)/$path' exceeds the accepted unit scope." } }
        $triggerSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); foreach ($path in $triggerPaths) { [void]$triggerSet.Add($path) }
        $carried = @($row.changed_paths | Where-Object { -not $triggerSet.Contains([string]$_) })
        Assert-SourceOnlyInputSetEqual $row.changed_paths @($triggerPaths + $carried) "Source '$([string]$row.repo_id)' trigger/carried partition"
        foreach ($path in $carried) { if (-not (Test-SourceOnlyInputPathAllowed $path @($row.project_allowed_paths))) { throw "Carried path '$([string]$row.repo_id)/$path' exceeds project scope." } }
        $planRows.Add([pscustomobject][ordered]@{
            dependency_ordinal = [int]$row.dependency_ordinal; repo_id = [string]$row.repo_id; publication_mode = [string]$row.publication_mode
            candidate_branch = [string]$row.candidate_branch; target_branch = [string]$row.target_branch; upstream = [string]$row.upstream; remote = [string]$row.remote; remote_url = [string]$row.remote_url
            old_revision = [string]$row.old_revision; old_tree = [string]$row.old_tree; candidate_revision = [string]$row.candidate_revision; candidate_tree = [string]$row.candidate_tree
            final_revision = $(if ([string]$row.publication_mode -ceq 'fast-forward') { [string]$row.candidate_revision } else { $null }); final_tree = [string]$row.candidate_tree
            changed_paths = @($row.changed_paths); trigger_unit_paths = @($triggerPaths); carried_paths = @($carried); validation_refs = @([string]$receipt.receipt_id); rollback_revision = [string]$row.old_revision
        })
    }
    $triggerKind = if (($c.unit.PSObject.Properties.Name -contains 'work_mode') -and [string]$c.unit.work_mode -ceq 'validation-only') { 'accepted-development-snapshot' } else { 'accepted-development-integration' }
    $receiptHash = Get-MorphospaceFileSha256 $receiptPath
    $plan = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.source_only_publication_plan.v1'; publication_id = $PublicationId; project_id = [string]$c.project.project_id; trigger_unit_id = $UnitId
        trigger = [pscustomobject][ordered]@{ kind = $triggerKind; accepted_status = 'accepted'; push_checkpoint = 'integration-batch' }
        acceptance_transition = [pscustomobject][ordered]@{ event_id = [string]$acceptanceEvent.event_id; transaction_id = $transactionId; validation_receipt = [pscustomobject][ordered]@{ path = $receiptRelative; sha256 = $receiptHash } }
        planning_owner = [pscustomobject][ordered]@{ repo_id = [string]$analysis.planning.repo_id; branch = [string]$analysis.planning.branch; head = [string]$analysis.planning.head; tree = [string]$analysis.planning.tree; remote_policy = 'no-configured-remotes' }
        expected = [pscustomobject][ordered]@{ project_sha256 = Get-MorphospaceCanonicalJsonSha256 $c.project; state_sha256 = Get-MorphospaceCanonicalJsonSha256 $c.state; unit_sha256 = Get-MorphospaceCanonicalJsonSha256 $c.unit; events_sha256 = Get-MorphospaceFileSha256 $c.events_path; events_length = [int64]([IO.FileInfo]$c.events_path).Length; event_tail_id = [string]$acceptanceEvent.event_id }
        source_repositories = @($planRows.ToArray())
        validation_evidence = @([pscustomobject][ordered]@{ evidence_id = [string]$receipt.receipt_id; path = $receiptRelative; sha256 = $receiptHash })
        preservation = [pscustomobject][ordered]@{ source_only = $true; planning_remote_required = $false; planning_remote_mutation_claimed = $false; planning_publication_performed = $false; unit_statuses_preserved = $true; acceptance_inferred = $false; validation_inferred = $false; wearer_acceptance_inferred = $false; force_push_allowed = $false }
    }
    [void](Assert-MorphospaceValidationReceiptStructure -Document $receipt -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1')
    $json = $plan | ConvertTo-Json -Depth 64
    if (-not (Test-Json -Json $json -SchemaFile (Join-Path $c.repo_root 'schemas\source-only-publication-plan-v1.schema.json'))) { throw 'Generated source-only publication plan does not satisfy its schema.' }
    return Write-SourceOnlyInputDocument $plan $OutPath
}

function Start-MorphospaceSourceOnlyPublicationOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PlanPath, [Parameter(Mandatory = $true)][string]$RepoId, [Parameter(Mandatory = $true)][string]$OutPath, [string]$Timestamp = '')
    $planPathFull = Resolve-SourceOnlyInputPath $PlanPath Leaf 'Prepared source-only plan'
    $plan = Read-MorphospaceProtocolJson $planPathFull
    $repoRoot = Split-Path $PSScriptRoot -Parent
    if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $planPathFull) -SchemaFile (Join-Path $repoRoot 'schemas\source-only-publication-plan-v1.schema.json'))) { throw 'Prepared source-only plan does not satisfy its schema.' }
    $matches = @($plan.source_repositories | Where-Object { [string]$_.repo_id -ceq $RepoId })
    if ($matches.Count -ne 1) { throw "Prepared plan does not contain exactly one source '$RepoId'." }
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    [void](Test-MorphospaceStrictUtcTimestamp $Timestamp)
    $document = [pscustomobject][ordered]@{ schema = 'rusty.morphospace.workflow.source_only_publication_operation_start.v1'; publication_id = [string]$plan.publication_id; plan_sha256 = Get-MorphospaceFileSha256 $planPathFull; dependency_ordinal = [int]$matches[0].dependency_ordinal; repo_id = $RepoId; operation_started_at = $Timestamp; preservation = [pscustomobject][ordered]@{ external_operation_performed = $false; git_mutation_performed = $false; execution_success_inferred = $false } }
    return Write-SourceOnlyInputDocument $document $OutPath
}

function Assert-SourceOnlyInputOperationEvidence {
    param(
        [object]$Evidence, [string]$EvidencePath, [string]$ExpectedSha256,
        [string]$OperationStartSha256, [object]$Start, [object]$Planned
    )
    if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-MorphospaceFileSha256 $EvidencePath) -cne $ExpectedSha256) { throw 'Operation-owner evidence does not match its expected SHA-256.' }
    Assert-MorphospaceExactPropertySet -Value $Evidence -Required @('schema', 'operation_start_sha256', 'provider', 'outcome', 'artifact') -Context 'Operation-owner evidence'
    Assert-MorphospaceExactPropertySet -Value $Evidence.provider -Required @('repo_id', 'executor_id') -Context 'Operation-owner evidence provider'
    Assert-MorphospaceExactPropertySet -Value $Evidence.outcome -Required @('operation_finished_at', 'push_mode', 'force_used', 'result') -Context 'Operation-owner evidence outcome'
    Assert-MorphospaceExactPropertySet -Value $Evidence.artifact -Required @('path', 'sha256') -Context 'Operation-owner evidence artifact'
    if ([string]$Evidence.schema -cne 'rusty.morphospace.workflow.source_only_publication_operation_evidence.v1' -or [string]$Evidence.operation_start_sha256 -cne $OperationStartSha256) { throw 'Operation-owner evidence does not bind the exact operation start marker.' }
    if ([string]$Evidence.provider.repo_id -cne [string]$Planned.repo_id -or [string]$Evidence.provider.repo_id -cne [string]$Start.repo_id -or [string]$Evidence.provider.executor_id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$') { throw 'Operation-owner evidence provider identity differs from the planned provider.' }
    if ([string]$Evidence.outcome.push_mode -cne 'fast-forward' -or $Evidence.outcome.force_used -isnot [bool] -or [bool]$Evidence.outcome.force_used -or [string]$Evidence.outcome.result -cne 'pass') { throw 'Operation-owner evidence does not attest a successful non-force operation.' }
    $startedAt = Test-MorphospaceStrictUtcTimestamp ([string]$Start.operation_started_at); $finishedAt = Test-MorphospaceStrictUtcTimestamp ([string]$Evidence.outcome.operation_finished_at)
    if ($finishedAt -lt $startedAt) { throw 'Operation-owner evidence completion precedes the operation start marker.' }
    $artifactRelative = ([string]$Evidence.artifact.path).Replace('\', '/')
    if ($artifactRelative -cnotmatch '^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$' -or [IO.Path]::IsPathRooted($artifactRelative)) { throw 'Operation-owner evidence artifact path is not a safe relative path.' }
    if ([string]$Evidence.artifact.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Operation-owner evidence artifact SHA-256 is invalid.' }
    $evidenceParent = Split-Path -Parent $EvidencePath; $artifactPath = [IO.Path]::GetFullPath((Join-Path $evidenceParent $artifactRelative)); $evidencePrefix = [IO.Path]::GetFullPath($evidenceParent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $artifactPath.StartsWith($evidencePrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or (Get-MorphospaceFileSha256 $artifactPath) -cne [string]$Evidence.artifact.sha256) { throw 'Operation-owner evidence artifact is missing, outside its evidence directory, or hash-mismatched.' }
    return [pscustomobject]@{ document = $Evidence; started_at = $startedAt; finished_at = $finishedAt }
}

function Complete-MorphospaceSourceOnlyPublicationOperationObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PlanPath, [Parameter(Mandatory = $true)][string]$OperationStartPath,
        [Parameter(Mandatory = $true)][string]$OperationEvidencePath, [Parameter(Mandatory = $true)][string]$ExpectedOperationEvidenceSha256,
        [Parameter(Mandatory = $true)][string]$RepoMapPath, [Parameter(Mandatory = $true)][string]$OutPath, [string]$Timestamp = ''
    )
    $planPathFull = Resolve-SourceOnlyInputPath $PlanPath Leaf 'Prepared source-only plan'; $plan = Read-MorphospaceProtocolJson $planPathFull
    $repoRoot = Split-Path $PSScriptRoot -Parent
    if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $planPathFull) -SchemaFile (Join-Path $repoRoot 'schemas\source-only-publication-plan-v1.schema.json'))) { throw 'Prepared source-only plan does not satisfy its schema.' }
    $startPathFull = Resolve-SourceOnlyInputPath $OperationStartPath Leaf 'Operation start'; $start = Read-MorphospaceProtocolJson $startPathFull
    Assert-MorphospaceExactPropertySet -Value $start -Required @('schema', 'publication_id', 'plan_sha256', 'dependency_ordinal', 'repo_id', 'operation_started_at', 'preservation') -Context 'Source-only operation start'
    Assert-MorphospaceExactPropertySet -Value $start.preservation -Required @('external_operation_performed', 'git_mutation_performed', 'execution_success_inferred') -Context 'Source-only operation start preservation'
    if ([string]$start.schema -cne 'rusty.morphospace.workflow.source_only_publication_operation_start.v1' -or [string]$start.publication_id -cne [string]$plan.publication_id -or [string]$start.plan_sha256 -cne (Get-MorphospaceFileSha256 $planPathFull)) { throw 'Operation start does not bind the exact prepared plan.' }
    foreach ($claim in @('external_operation_performed', 'git_mutation_performed', 'execution_success_inferred')) { if ($start.preservation.$claim -isnot [bool]) { throw 'Operation start contains a non-Boolean preservation claim.' } }
    if ([bool]$start.preservation.external_operation_performed -or [bool]$start.preservation.git_mutation_performed -or [bool]$start.preservation.execution_success_inferred) { throw 'Operation start contains an invalid preservation claim.' }
    $planned = @($plan.source_repositories | Where-Object { [string]$_.repo_id -ceq [string]$start.repo_id })
    if ($planned.Count -ne 1 -or [int]$planned[0].dependency_ordinal -ne [int]$start.dependency_ordinal) { throw 'Operation start does not bind one planned source ordinal.' }
    $evidencePathFull = Resolve-SourceOnlyInputPath $OperationEvidencePath Leaf 'Operation-owner evidence'; $evidence = Read-MorphospaceProtocolJson $evidencePathFull; $startHash = Get-MorphospaceFileSha256 $startPathFull
    $attestation = Assert-SourceOnlyInputOperationEvidence -Evidence $evidence -EvidencePath $evidencePathFull -ExpectedSha256 $ExpectedOperationEvidenceSha256 -OperationStartSha256 $startHash -Start $start -Planned $planned[0]
    $mapPathFull = Resolve-SourceOnlyInputPath $RepoMapPath Leaf 'Repository map'
    if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $mapPathFull) -SchemaFile (Join-Path $repoRoot 'schemas\repository-map.schema.json'))) { throw 'Repository map does not satisfy its schema.' }
    $map = Read-MorphospaceProtocolJson $mapPathFull
    $mapped = @($map.repositories | Where-Object { [string]$_.role -ceq 'source' -and [string]$_.repo_id -ceq [string]$start.repo_id })
    if ($mapped.Count -ne 1) { throw 'Operation source is not uniquely mapped.' }
    $repository = Resolve-SourceOnlyInputPath ([string]$mapped[0].path) Container 'Operation source repository'
    Assert-SourceOnlyInputRemoteUrl ([string]$planned[0].remote_url) ([string]$planned[0].repo_id)
    if (@((Invoke-SourceOnlyInputGit $repository @('status', '--porcelain=v1', '--untracked-files=all')).lines).Count -ne 0) { throw 'Operation source repository drifted or is dirty.' }
    $head = (Get-SourceOnlyInputGitValue $repository @('rev-parse', 'HEAD') 'Operation source HEAD').ToLowerInvariant()
    if ($head -cne [string]$planned[0].candidate_revision) { throw 'Operation source candidate drifted after preparation.' }
    $readback = Get-SourceOnlyInputRemoteReadback $repository ([string]$planned[0].remote_url) ([string]$planned[0].target_branch)
    if ($readback.status -cne 'observed') { throw "Remote readback is unavailable; retain the operation start and rerun observation for '$([string]$start.repo_id)'." }
    $final = [string]$readback.revision
    if ([string]$planned[0].publication_mode -ceq 'fast-forward') {
        if ($final -cne [string]$planned[0].candidate_revision) { throw 'Observed fast-forward final does not equal the candidate.' }
    } else {
        $parentsResult = Invoke-SourceOnlyInputGit $repository @('rev-list', '--parents', '-n', '1', $final)
        $parents = @(([string]$parentsResult.lines[0]).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
        if ($parents.Count -ne 3 -or $parents[0] -cne $final -or $parents[1] -cne [string]$planned[0].old_revision -or $parents[2] -cne [string]$planned[0].candidate_revision) { throw 'Observed provider merge does not have the exact ordered old and candidate parents.' }
        $tree = (Get-SourceOnlyInputGitValue $repository @('rev-parse', "$final^{tree}") 'Observed provider merge tree').ToLowerInvariant()
        if ($tree -cne [string]$planned[0].candidate_tree) { throw 'Observed provider merge tree differs from the candidate tree.' }
    }
    if (-not $Timestamp) { $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    $startedAt = Test-MorphospaceStrictUtcTimestamp ([string]$start.operation_started_at); $readbackAt = Test-MorphospaceStrictUtcTimestamp $Timestamp
    if ($readbackAt -lt $startedAt -or $readbackAt -lt $attestation.finished_at) { throw 'Remote readback precedes the operation start or attested completion.' }
    $document = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.source_only_publication_operation_observation.v1'; publication_id = [string]$plan.publication_id; plan_sha256 = Get-MorphospaceFileSha256 $planPathFull
        operation_start = [pscustomobject][ordered]@{ path = $startPathFull; sha256 = Get-MorphospaceFileSha256 $startPathFull; dependency_ordinal = [int]$start.dependency_ordinal; repo_id = [string]$start.repo_id; operation_started_at = [string]$start.operation_started_at }
        operation_evidence = [pscustomobject][ordered]@{ path = $evidencePathFull; sha256 = $ExpectedOperationEvidenceSha256; schema = [string]$evidence.schema; executor_id = [string]$evidence.provider.executor_id; operation_finished_at = [string]$evidence.outcome.operation_finished_at; push_mode = [string]$evidence.outcome.push_mode; force_used = [bool]$evidence.outcome.force_used; result = [string]$evidence.outcome.result }
        final_revision = $final; remote_readback_revision = $final; remote_readback_at = $Timestamp; result = 'observed-published'
        preservation = [pscustomobject][ordered]@{ git_mutation_performed = $false; force_inferred = $false; authorization_inferred = $false; acceptance_inferred = $false }
    }
    return Write-SourceOnlyInputDocument $document $OutPath
}

function New-MorphospaceSourceOnlyPublicationExecution {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PlanPath, [Parameter(Mandatory = $true)][string[]]$OperationObservationPaths, [Parameter(Mandatory = $true)][string]$RepoMapPath, [Parameter(Mandatory = $true)][string]$OutPath)
    $planPathFull = Resolve-SourceOnlyInputPath $PlanPath Leaf 'Prepared source-only plan'; $plan = Read-MorphospaceProtocolJson $planPathFull; $planHash = Get-MorphospaceFileSha256 $planPathFull
    $repoRoot = Split-Path $PSScriptRoot -Parent
    if (-not (Test-Json -Json (Get-Content -Raw -LiteralPath $planPathFull) -SchemaFile (Join-Path $repoRoot 'schemas\source-only-publication-plan-v1.schema.json'))) { throw 'Prepared source-only plan does not satisfy its schema.' }
    if ($OperationObservationPaths.Count -ne @($plan.source_repositories).Count) { throw 'Operation observation count differs from the plan.' }
    $executionRows = [Collections.Generic.List[object]]::new(); $priorReadback = $null
    for ($i = 0; $i -lt @($plan.source_repositories).Count; $i++) {
        $planned = @($plan.source_repositories)[$i]
        $path = Resolve-SourceOnlyInputPath $OperationObservationPaths[$i] Leaf 'Operation observation'; $observation = Read-MorphospaceProtocolJson $path
        Assert-MorphospaceExactPropertySet -Value $observation -Required @('schema', 'publication_id', 'plan_sha256', 'operation_start', 'operation_evidence', 'final_revision', 'remote_readback_revision', 'remote_readback_at', 'result', 'preservation') -Context 'Source-only operation observation'
        Assert-MorphospaceExactPropertySet -Value $observation.operation_start -Required @('path', 'sha256', 'dependency_ordinal', 'repo_id', 'operation_started_at') -Context 'Source-only operation observation start'
        Assert-MorphospaceExactPropertySet -Value $observation.operation_evidence -Required @('path', 'sha256', 'schema', 'executor_id', 'operation_finished_at', 'push_mode', 'force_used', 'result') -Context 'Source-only operation observation evidence'
        Assert-MorphospaceExactPropertySet -Value $observation.preservation -Required @('git_mutation_performed', 'force_inferred', 'authorization_inferred', 'acceptance_inferred') -Context 'Source-only operation observation preservation'
        if ([string]$observation.schema -cne 'rusty.morphospace.workflow.source_only_publication_operation_observation.v1' -or [string]$observation.publication_id -cne [string]$plan.publication_id -or [string]$observation.plan_sha256 -cne $planHash -or [int]$observation.operation_start.dependency_ordinal -ne ($i + 1) -or [string]$observation.operation_start.repo_id -cne [string]$planned.repo_id -or [string]$observation.result -cne 'observed-published') { throw "Operation observation differs at dependency ordinal $($i + 1)." }
        $startPath = Resolve-SourceOnlyInputPath ([string]$observation.operation_start.path) Leaf 'Referenced operation start'
        if ([string]$observation.operation_start.sha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-MorphospaceFileSha256 $startPath) -cne [string]$observation.operation_start.sha256) { throw 'Referenced operation start does not match its observation SHA-256.' }
        $start = Read-MorphospaceProtocolJson $startPath
        Assert-MorphospaceExactPropertySet -Value $start -Required @('schema', 'publication_id', 'plan_sha256', 'dependency_ordinal', 'repo_id', 'operation_started_at', 'preservation') -Context 'Referenced operation start'
        Assert-MorphospaceExactPropertySet -Value $start.preservation -Required @('external_operation_performed', 'git_mutation_performed', 'execution_success_inferred') -Context 'Referenced operation start preservation'
        if ([string]$start.schema -cne 'rusty.morphospace.workflow.source_only_publication_operation_start.v1' -or [string]$start.publication_id -cne [string]$plan.publication_id -or [string]$start.plan_sha256 -cne $planHash -or [int]$start.dependency_ordinal -ne ($i + 1) -or [string]$start.repo_id -cne [string]$planned.repo_id -or [string]$start.operation_started_at -cne [string]$observation.operation_start.operation_started_at) { throw 'Referenced operation start does not bind its plan and observation.' }
        foreach ($claim in @('external_operation_performed', 'git_mutation_performed', 'execution_success_inferred')) { if ($start.preservation.$claim -isnot [bool]) { throw 'Referenced operation start contains a non-Boolean preservation claim.' } }
        if ([bool]$start.preservation.external_operation_performed -or [bool]$start.preservation.git_mutation_performed -or [bool]$start.preservation.execution_success_inferred) { throw 'Referenced operation start contains an invalid preservation claim.' }
        $evidencePath = Resolve-SourceOnlyInputPath ([string]$observation.operation_evidence.path) Leaf 'Referenced operation-owner evidence'
        $evidence = Read-MorphospaceProtocolJson $evidencePath
        $attestation = Assert-SourceOnlyInputOperationEvidence -Evidence $evidence -EvidencePath $evidencePath -ExpectedSha256 ([string]$observation.operation_evidence.sha256) -OperationStartSha256 ([string]$observation.operation_start.sha256) -Start $start -Planned $planned
        if ([string]$observation.operation_evidence.schema -cne [string]$evidence.schema -or [string]$observation.operation_evidence.executor_id -cne [string]$evidence.provider.executor_id -or [string]$observation.operation_evidence.operation_finished_at -cne [string]$evidence.outcome.operation_finished_at -or [string]$observation.operation_evidence.push_mode -cne [string]$evidence.outcome.push_mode -or [bool]$observation.operation_evidence.force_used -ne [bool]$evidence.outcome.force_used -or [string]$observation.operation_evidence.result -cne [string]$evidence.outcome.result) { throw 'Operation observation differs from its exact operation-owner evidence.' }
        if ([string]$observation.final_revision -cne [string]$observation.remote_readback_revision -or [string]$observation.operation_evidence.schema -cne 'rusty.morphospace.workflow.source_only_publication_operation_evidence.v1' -or [string]$observation.operation_evidence.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$observation.operation_evidence.executor_id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$' -or [string]$observation.operation_evidence.push_mode -cne 'fast-forward' -or $observation.operation_evidence.force_used -isnot [bool] -or [bool]$observation.operation_evidence.force_used -or [string]$observation.operation_evidence.result -cne 'pass') { throw 'Operation observation lacks valid bound non-force operation-owner evidence.' }
        foreach ($claim in @('git_mutation_performed', 'force_inferred', 'authorization_inferred', 'acceptance_inferred')) { if ($observation.preservation.$claim -isnot [bool]) { throw 'Operation observation contains a non-Boolean preservation claim.' } }
        if ([bool]$observation.preservation.git_mutation_performed -or [bool]$observation.preservation.force_inferred -or [bool]$observation.preservation.authorization_inferred -or [bool]$observation.preservation.acceptance_inferred) { throw 'Operation observation contains an invalid preservation claim.' }
        $started = Test-MorphospaceStrictUtcTimestamp ([string]$observation.operation_start.operation_started_at); $finished = Test-MorphospaceStrictUtcTimestamp ([string]$observation.operation_evidence.operation_finished_at); $readback = Test-MorphospaceStrictUtcTimestamp ([string]$observation.remote_readback_at)
        if ($finished -lt $started -or $readback -lt $finished -or ($null -ne $priorReadback -and $started -lt $priorReadback)) { throw 'Operation observations are not chronologically ordered by dependency ordinal.' }
        $priorReadback = $readback
        $executionRows.Add([pscustomobject][ordered]@{ dependency_ordinal = $i + 1; repo_id = [string]$planned.repo_id; publication_mode = [string]$planned.publication_mode; old_revision = [string]$planned.old_revision; candidate_revision = [string]$planned.candidate_revision; final_revision = [string]$observation.final_revision; remote_readback_revision = [string]$observation.remote_readback_revision; operation_started_at = [string]$observation.operation_start.operation_started_at; remote_readback_at = [string]$observation.remote_readback_at; push_mode = [string]$observation.operation_evidence.push_mode; force_used = [bool]$observation.operation_evidence.force_used; result = [string]$observation.operation_evidence.result })
    }
    [string[]]$reverse = @($plan.source_repositories | ForEach-Object { [string]$_.repo_id }); [Array]::Reverse($reverse)
    $rows = @($executionRows.ToArray())
    $execution = [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.source_only_publication_execution.v1'; publication_id = [string]$plan.publication_id; project_id = [string]$plan.project_id; trigger_unit_id = [string]$plan.trigger_unit_id
        plan = [pscustomobject][ordered]@{ path = "receipts/$([string]$plan.publication_id)-plan.json"; sha256 = $planHash }
        started_at = [string]$rows[0].operation_started_at; finished_at = [string]$rows[-1].remote_readback_at; source_repositories = $rows
        rollback = [pscustomobject][ordered]@{ reverse_dependency_order = @($reverse); required = $false }
        preservation = [pscustomobject][ordered]@{ planning_remote_mutation_performed = $false; planning_feature_ref_created = $false; planning_publication_claimed = $false; unit_statuses_changed = $false; acceptance_changed = $false; validation_changed = $false; wearer_acceptance_changed = $false; device_mutation_performed = $false; release_claimed = $false }
    }
    $json = $execution | ConvertTo-Json -Depth 64
    if (-not (Test-Json -Json $json -SchemaFile (Join-Path $repoRoot 'schemas\source-only-publication-execution-v1.schema.json'))) { throw 'Generated source-only publication execution does not satisfy its schema.' }
    return Write-SourceOnlyInputDocument $execution $OutPath
}

Export-ModuleMember -Function `
    Get-MorphospaceSourceOnlyPublicationReadiness, New-MorphospaceSourceOnlyPublicationPlan, `
    Start-MorphospaceSourceOnlyPublicationOperation, Complete-MorphospaceSourceOnlyPublicationOperationObservation, `
    New-MorphospaceSourceOnlyPublicationExecution
