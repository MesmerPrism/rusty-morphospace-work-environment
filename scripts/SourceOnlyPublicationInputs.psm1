Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceContentObservation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceTransitionLedger.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationReceipt.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AcceptedValidationEvidenceRelocation.psm1') -Force

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

function Get-SourceOnlyAcceptedTrigger {
    param($Context,[string]$UnitId,[string]$AcceptanceEventId='', [bool]$RequireCurrent=$true)
    $c=$Context
    if ([string]$c.unit.status -cne 'accepted' -or ($RequireCurrent -and ($null -ne $c.state.current_unit -or $null -ne $c.state.pending_push_bundle))) { throw 'Plan generation requires the exact accepted idle trigger with no pending publication bundle.' }
    $relocation = $null
    if ($AcceptanceEventId -and $AcceptanceEventId -cne [string]$c.tail.event_id) {
        Assert-SourceDelivery (-not $RequireCurrent) 'Accepted source owner is not the current acceptance tail.'
        $retained=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $c.workspace -TransactionId "$AcceptanceEventId-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$UnitId.json" -ExpectedEventsPath 'iteration-events.jsonl'
        $c=[pscustomobject]@{workspace=$c.workspace;unit=$c.unit;project=$c.project;tail=$retained.intent.event;state=$retained.intent.target.state.document}
    }
    if ([string]$c.tail.event_id -cmatch '-accepted-evidence-relocated-[0-9]{4,}$') {
        $relocation = Test-MorphospaceAcceptedEvidenceRelocation -WorkspaceRoot $c.workspace -RelocationId ([string]$c.tail.event_id) -RequireTail
        if ([string]$relocation.document.unit_id -cne $UnitId) { throw 'Accepted evidence relocation belongs to another trigger unit.' }
        $acceptanceEvent = $relocation.acceptance_event
    } else {
        $acceptanceEvent = $c.tail
    }
    if ([string]$acceptanceEvent.unit_id -cne $UnitId -or [string]$acceptanceEvent.event_id -cnotmatch ('^' + [regex]::Escape($UnitId) + '-accepted-[0-9]{4,}$') -or @($acceptanceEvent.receipts).Count -ne 1) { throw 'Event-ledger tail is not the exact acceptance transition for the trigger unit.' }
    $receiptRelative = [string]$acceptanceEvent.receipts[0]
    if ($receiptRelative -cne [string]$c.state.last_accepted_receipt -or $receiptRelative -cne [string]$c.state.validation_checkpoint.receipt) { throw 'Accepted state does not bind the tail validation receipt.' }
    $receiptPath = Resolve-MorphospaceWorkspacePath $c.workspace $receiptRelative -RequireLeaf
    $receipt = Assert-MorphospaceValidationReceiptStructure -ReceiptPath $receiptPath -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1'
    if ([string]$receipt.project_id -cne [string]$c.project.project_id -or [string]$receipt.unit_id -cne $UnitId -or [string]$receipt.result -cne 'pass') { throw 'Accepted validation receipt is not a passing receipt for this project and unit.' }
    foreach ($artifact in @($receipt.artifacts)) {
        $relocated = @(if ($null -ne $relocation) { $relocation.document.artifacts | Where-Object { [string]$_.artifact_id -ceq [string]$artifact.artifact_id } })
        $artifactPath = if ($relocated.Count -eq 1) { Resolve-MorphospaceWorkspacePath $c.workspace ([string]$relocated[0].local_path) -RequireLeaf } elseif ([IO.Path]::IsPathRooted([string]$artifact.path)) { [IO.Path]::GetFullPath([string]$artifact.path) } else { [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $receiptPath) ([string]$artifact.path))) }
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or (Get-MorphospaceFileSha256 $artifactPath) -cne ([string]$artifact.sha256).ToLowerInvariant()) { throw "Accepted validation artifact '$([string]$artifact.artifact_id)' drifted." }
    }
    $transactionId = "$([string]$acceptanceEvent.event_id)-transition"
    $acceptedLedger=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $c.workspace -TransactionId $transactionId -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$UnitId.json" -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail:($RequireCurrent -and $null -eq $relocation)
    [pscustomobject]@{receipt=$receipt;receipt_path=$receiptPath;receipt_relative=$receiptRelative;transaction_id=$transactionId;acceptance_event=$acceptanceEvent;ledger=$acceptedLedger;relocation=$relocation}
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
    $accepted=Get-SourceOnlyAcceptedTrigger -Context $c -UnitId $UnitId
    $receipt=$accepted.receipt;$receiptPath=$accepted.receipt_path;$receiptRelative=$accepted.receipt_relative;$transactionId=$accepted.transaction_id;$acceptanceEvent=$accepted.acceptance_event;$relocation=$accepted.relocation
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
        expected = [pscustomobject][ordered]@{ project_sha256 = Get-MorphospaceCanonicalJsonSha256 $c.project; state_sha256 = Get-MorphospaceCanonicalJsonSha256 $c.state; unit_sha256 = Get-MorphospaceCanonicalJsonSha256 $c.unit; events_sha256 = Get-MorphospaceFileSha256 $c.events_path; events_length = [int64]([IO.FileInfo]$c.events_path).Length; event_tail_id = [string]$c.tail.event_id }
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

function Assert-SourceDelivery([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Source delivery: $Message" }
}

function New-SourceDeliveryObservation {
    $comparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    return [Collections.Generic.Dictionary[string,string]]::new($comparer)
}

function Get-SourceDeliveryReference([string]$Path) {
    $full = Resolve-SourceOnlyInputPath $Path Leaf 'Source delivery evidence'
    Assert-MorphospaceNoReparseAncestor -Root ([IO.Path]::GetPathRoot($full)) -Candidate $full
    [pscustomobject][ordered]@{ path = $full; sha256 = Get-MorphospaceFileSha256 $full }
}

function Read-SourceDeliveryReference($Reference, [Collections.IDictionary]$Observed, [switch]$Bytes) {
    Assert-MorphospaceExactPropertySet $Reference @('path','sha256') @('bytes') 'Source delivery reference'
    $actual = Get-SourceDeliveryReference ([string]$Reference.path)
    Assert-SourceDelivery ($actual.sha256 -ceq [string]$Reference.sha256) 'Evidence bytes changed.'
    $raw = [IO.File]::ReadAllBytes($actual.path)
    if ($Reference.PSObject.Properties.Name -ccontains 'bytes') { Assert-SourceDelivery ($Reference.bytes -eq $raw.Length) 'Evidence length differs.' }
    Assert-SourceDelivery ((Get-MorphospaceSha256Bytes $raw) -ceq $actual.sha256) 'Evidence changed during read.'
    if($Observed.ContainsKey($actual.path)) { Assert-SourceDelivery ([string]$Observed[$actual.path] -ceq $actual.sha256) 'One evidence locator was rebound during the observation.' }
    $Observed[$actual.path] = $actual.sha256
    if ($Bytes) { return ,$raw }
    ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $raw -Context 'Source delivery evidence'
}

function Assert-SourceDeliveryObservation([Collections.IDictionary]$Observed) {
    foreach ($path in $Observed.Keys) {
        Assert-SourceDelivery ((Get-MorphospaceFileSha256 $path) -ceq $Observed[$path]) 'Evidence drifted before publication.'
    }
}

function Read-SourceDeliveryDocument([string]$Path, [string]$ExpectedSha256, [string]$Kind, [Collections.IDictionary]$Observed) {
    $doc = Read-SourceDeliveryReference ([pscustomobject]@{path=$Path;sha256=$ExpectedSha256}) $Observed
    $schema = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas/source-delivery-disposition-v1.schema.json'
    Assert-SourceDelivery ((Test-Json -Json ($doc|ConvertTo-Json -Depth 100) -SchemaFile $schema) -and [string]$doc.kind -ceq $Kind) "Invalid closed $Kind document."
    return $doc
}

function Get-SourceDeliveryRepository($Subject, $Map) {
    Assert-SourceDelivery (Test-Json -Json ($Map|ConvertTo-Json -Depth 40) -SchemaFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas/repository-map.schema.json')) 'Publication map does not satisfy the existing map contract.'
    $rows = @($Map.repositories | Where-Object { [string]$_.repo_id -ceq [string]$Subject.repo_id -and [string]$_.role -ceq 'source' })
    Assert-SourceDelivery ($rows.Count -eq 1) 'Publication source must be uniquely mapped.'
    $root = Resolve-SourceOnlyInputPath ([string]$rows[0].path) Container 'Publication source'
    foreach ($pair in @(@($Subject.base_commit,$Subject.base_tree), @($Subject.candidate_commit,$Subject.candidate_tree))) {
        Assert-SourceDelivery ((Get-SourceOnlyInputGitValue $root @('rev-parse',"$($pair[0])^{tree}") 'Source tree') -ceq $pair[1]) 'Publication source commit/tree differs.'
    }
    Assert-SourceDelivery ((Invoke-SourceOnlyInputGit $root @('merge-base','--is-ancestor',$Subject.base_commit,$Subject.candidate_commit) -AllowFailure).exit_code -eq 0) 'Publication base is not an ancestor.'
    $changed = @(Get-SourceOnlyInputSortedPaths @((Invoke-SourceOnlyInputGit $root @('diff','--name-only','--no-renames',"$($Subject.base_commit)..$($Subject.candidate_commit)",'--')).lines | Where-Object {$_}) 'Publication changed paths')
    Assert-SourceDelivery ($changed.Count -gt 0) 'Publication subject has no source delta.'
    foreach ($path in $changed) { Assert-SourceDelivery (Test-SourceOnlyInputPathAllowed $path @($Subject.allowed_paths)) 'Publication source exceeds its declared paths.' }
    $remote = Get-SourceOnlyInputGitValue $root @('remote','get-url','origin') 'Source remote'
    Assert-SourceOnlyInputRemoteUrl $remote ([string]$Subject.repo_id)
    Assert-SourceDelivery ($remote -cmatch ('^(?:https://github[.]com/|git@github[.]com:)' + [regex]::Escape([string]$Subject.repository) + '(?:[.]git)?$')) 'Source remote repository differs.'
    return $root
}

function Assert-SourceDeliveryCheckout([string]$Root,$Subject) {
    Assert-SourceDelivery ((Get-SourceOnlyInputGitValue $Root @('rev-parse','HEAD') 'Source HEAD') -ceq $Subject.candidate_commit -and @((Invoke-SourceOnlyInputGit $Root @('status','--porcelain=v1','--untracked-files=all')).lines).Count -eq 0) 'Publication checkout is not the clean subject.'
}

function Get-SourceDeliveryAcceptedOwner([string]$WorkspaceRoot,$Request,[switch]$Creating,[Collections.IDictionary]$Observed) {
    $c=$Request.consumer;$ws=[IO.Path]::GetFullPath($WorkspaceRoot)
    Assert-SourceDelivery ($ws -ceq [IO.Path]::GetFullPath($c.workspace_root) -and (Get-MorphospaceFileSha256 $c.repository_map.path) -ceq $c.repository_map.sha256) 'Accepted owner locator/map differs.'
    $context=Get-SourceOnlyInputContext $ws $c.unit_id $c.repository_map.path
    $accepted=Get-SourceOnlyAcceptedTrigger -Context $context -UnitId $c.unit_id -AcceptanceEventId $c.accept_event_id -RequireCurrent:$Creating
    Assert-SourceDelivery ($context.project.project_id -ceq $c.project_id -and $accepted.acceptance_event.event_id -ceq $c.accept_event_id -and (Get-MorphospaceCanonicalJsonSha256 $context.unit) -ceq $accepted.ledger.intent.target.unit.sha256) 'Accepted source owner contract is detached.'
    # Accepted units with a frozen candidate retain that original map. This
    # does not manufacture a Freeze prerequisite for genuine initial owners.
    $marker=$context.unit.PSObject.Properties['candidate_freeze']
    if($null -ne $marker -and $null -ne $marker.Value) {
        $frozen=$marker.Value
        $freezePath=Resolve-MorphospaceWorkspacePath $ws ([string]$frozen.receipt_path) -RequireLeaf
        $freeze=Read-SourceDeliveryReference ([pscustomobject]@{path=$freezePath;sha256=[string]$frozen.receipt_sha256}) $Observed
        Assert-SourceDelivery ($freeze.project_id -ceq $c.project_id -and $freeze.unit_id -ceq $c.unit_id -and $freeze.freeze_id -ceq $frozen.freeze_id -and $c.repository_map.sha256 -ceq $freeze.expected.repository_map_sha256 -and [IO.Path]::GetFullPath($c.repository_map.path) -ceq [IO.Path]::GetFullPath((Resolve-MorphospaceWorkspacePath $ws $freeze.expected.repository_map_path -RequireLeaf))) 'Accepted frozen owner original repository map differs.'
    }
    $receiptPath=Resolve-MorphospaceWorkspacePath $ws ([string]$accepted.acceptance_event.receipts[0]) -RequireLeaf
    Assert-SourceDelivery ([IO.Path]::GetFullPath($c.accept_receipt.path) -ceq $receiptPath -and (Get-MorphospaceFileSha256 $receiptPath) -ceq $c.accept_receipt.sha256) 'Accepted source receipt binding differs.'
    $rows=@($accepted.receipt.repository_revisions|Where-Object repo_id -CEQ $Request.source_reference.repo_id)
    Assert-SourceDelivery ($rows.Count -eq 1 -and $rows[0].head_revision -ceq $Request.source_reference.commit -and $rows[0].head_revision -ceq $Request.publication_subject.candidate_commit) 'Accepted source revision differs from publication subject.'
    $scope=@($context.unit.allowed_repositories|Where-Object repo_id -CEQ $Request.publication_subject.repo_id)
    Assert-SourceDelivery ($scope.Count -eq 1) 'Publication source is absent from accepted write authority.'
    # Qualification and publication can start at different revisions. Preserve
    # the receipt's exact qualified interval; never transfer its results to
    # carried source. The complete publication interval has its own later proof.
    $triggerPaths=@($accepted.receipt.changed_paths|Where-Object repo_id -CEQ $Request.source_reference.repo_id)
    foreach($path in $triggerPaths) { Assert-SourceDelivery (Test-SourceOnlyInputPathAllowed $path.path @($scope[0].allowed_paths)) 'Accepted trigger path exceeds unit source authority.' }
    $projectScope=@($context.project.repositories|Where-Object repo_id -CEQ $Request.publication_subject.repo_id)
    Assert-SourceDelivery ($projectScope.Count -eq 1) 'Publication source is absent from accepted project authority.'
    foreach($path in @($Request.publication_subject.allowed_paths)) { Assert-SourceDelivery (Test-SourceOnlyInputPathAllowed $path @($projectScope[0].allowed_paths)) 'Publication paths exceed project source authority.' }
    if($Creating) {
        Assert-SourceDelivery ((Get-MorphospaceFileSha256 $context.unit_path) -ceq $c.unit_raw_sha256 -and (Get-MorphospaceFileSha256 $context.state_path) -ceq $c.state_raw_sha256 -and (Get-MorphospaceFileSha256 $context.events_path) -ceq $c.events_raw_sha256) 'Accepted source owner live preimage drifted.'
    }
    [pscustomobject]@{unit=$context.unit;original_unit=$accepted.ledger.intent.target.unit.document}
}

function Get-SourceDeliveryFrozenConsumer([string]$WorkspaceRoot, $Request, [switch]$Creating,[Collections.IDictionary]$Observed) {
    if($Request.consumer.boundary_kind -ceq 'accepted-source-owner'){return Get-SourceDeliveryAcceptedOwner $WorkspaceRoot $Request -Creating:$Creating -Observed $Observed}
    $ws = [IO.Path]::GetFullPath($WorkspaceRoot)
    Assert-SourceDelivery ($ws -ceq [IO.Path]::GetFullPath($Request.consumer.workspace_root)) 'Consumer workspace locator differs.'
    $c = $Request.consumer; $unitPath = "iteration-units/$($c.unit_id).json"
    $unit = Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $ws $unitPath -RequireLeaf)
    Assert-SourceDelivery ($unit.project_id -ceq $c.project_id -and $unit.unit_id -ceq $c.unit_id -and $unit.candidate_freeze.freeze_id -ceq $c.freeze_id -and $unit.candidate_freeze.receipt_sha256 -ceq $c.freeze_receipt_sha256) 'Consumer frozen identity differs.'
    $freezePath = Resolve-MorphospaceWorkspacePath $ws ([string]$unit.candidate_freeze.receipt_path) -RequireLeaf
    Assert-SourceDelivery ((Get-MorphospaceFileSha256 $freezePath) -ceq $c.freeze_receipt_sha256) 'Consumer freeze receipt drifted.'
    $freeze = Read-MorphospaceProtocolJson $freezePath
    Assert-SourceDelivery ($freeze.project_id -ceq $c.project_id -and $freeze.unit_id -ceq $c.unit_id -and $freeze.freeze_id -ceq $c.freeze_id) 'Frozen receipt subject differs.'
    foreach($fixed in @(@('project.spec.json',$freeze.expected.project_sha256),@('feature.lock.json',$freeze.expected.feature_lock_sha256))) {
        Assert-SourceDelivery ((Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson (Resolve-MorphospaceWorkspacePath $ws $fixed[0] -RequireLeaf))) -ceq $fixed[1]) 'Frozen consumer authority drifted.'
    }
    Assert-SourceDelivery ((Get-MorphospaceFileSha256 (Resolve-MorphospaceWorkspacePath $ws $freeze.expected.source_composition_path -RequireLeaf)) -ceq $freeze.expected.source_composition_sha256) 'Frozen consumer source lock drifted.'
    Assert-SourceDelivery ($c.repository_map.sha256 -ceq $freeze.expected.repository_map_sha256 -and [IO.Path]::GetFullPath($c.repository_map.path) -ceq [IO.Path]::GetFullPath((Resolve-MorphospaceWorkspacePath $ws $freeze.expected.repository_map_path -RequireLeaf)) -and (Get-MorphospaceFileSha256 $c.repository_map.path) -ceq $c.repository_map.sha256) 'Original consumer repository map differs.'
    $ft = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $ws -TransactionId "$($c.freeze_id)-recorded-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $unitPath -ExpectedEventsPath 'iteration-events.jsonl'
    $bt = Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $ws -TransactionId "$($c.begin_event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $unitPath -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail:$Creating
    Assert-SourceDelivery ($ft.intent.target.unit.document.status -ceq 'active' -and $bt.intent.target.unit.document.status -ceq 'validating' -and $bt.intent.event.sequence -eq ($ft.intent.event.sequence + 1) -and $bt.intent.pre.unit.sha256 -ceq $ft.intent.target.unit.sha256 -and $bt.intent.pre.state.sha256 -ceq $ft.intent.target.state.sha256 -and $bt.intent.target.unit.document.candidate_freeze.receipt_sha256 -ceq $c.freeze_receipt_sha256) 'Consumer requires its authenticated immediate Freeze and Begin.'
    $rows = @($freeze.final_repositories | Where-Object repo_id -CEQ $Request.source_reference.repo_id)
    Assert-SourceDelivery ($rows.Count -eq 1 -and $rows[0].commit -ceq $Request.source_reference.commit -and $rows[0].tree -ceq $Request.source_reference.tree) 'Frozen source reference differs from publication subject provenance.'
    if ($Creating) {
        $statePath = Join-Path $ws 'workspace.state.json'; $livePath = Join-Path $ws $unitPath
        Assert-SourceDelivery ((Get-MorphospaceFileSha256 $statePath) -ceq $c.state_raw_sha256 -and (Get-MorphospaceFileSha256 $livePath) -ceq $c.unit_raw_sha256 -and (Get-MorphospaceFileSha256 (Join-Path $ws 'iteration-events.jsonl')) -ceq $c.events_raw_sha256) 'Consumer live preimage drifted.'
        Assert-SourceDelivery ($unit.status -ceq 'validating' -and (Get-MorphospaceCanonicalJsonSha256 $unit) -ceq $bt.intent.target.unit.sha256 -and (Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $statePath)) -ceq $bt.intent.target.state.sha256) 'Consumer is not the exact committed Begin projection.'
    } else {
        $state=Read-MorphospaceProtocolJson (Join-Path $ws 'workspace.state.json')
        $latest=if($state.last_event_id -ceq $c.begin_event_id){$bt}else{Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $ws -TransactionId "$($state.last_event_id)-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath $unitPath -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail}
        Assert-SourceDelivery ($latest.event_tail_id -ceq $state.last_event_id -and (Get-MorphospaceCanonicalJsonSha256 $unit) -ceq $latest.intent.target.unit.sha256 -and (Get-MorphospaceCanonicalJsonSha256 $state) -ceq $latest.intent.target.state.sha256) 'Consumer live projection is detached from its committed continuation.'
    }
    return [pscustomobject]@{unit=$unit; original_unit=$bt.intent.target.unit.document}
}

function Assert-SourceDeliveryImmutableRequest($Request,$OriginalUnit,[Collections.IDictionary]$Observed) {
    [void](Read-SourceDeliveryReference $request.ordering_supersession.human_decision $Observed -Bytes)
    foreach ($dependency in @($request.ordering_supersession.prior_dependency_refs)) {
        $value = $OriginalUnit
        foreach ($part in $dependency.unit_json_pointer.TrimStart('/').Split('/')) {
            Assert-SourceDelivery ($part -cnotmatch '~|^$') 'Unsupported dependency pointer.'
            if ($value -is [array]) { Assert-SourceDelivery ($part -cmatch '^(0|[1-9][0-9]*)$' -and [int]$part -lt $value.Count) 'Dependency index differs.'; $value=$value[[int]$part] }
            else { Assert-SourceDelivery ($value.PSObject.Properties.Name -ccontains $part) 'Dependency pointer is missing.'; $value=$value.$part }
        }
        Assert-SourceDelivery ((Get-MorphospaceCanonicalJsonSha256 $value) -ceq $dependency.value_sha256) 'Declared old publication dependency differs.'
    }
    [void](Read-SourceDeliveryReference $request.relationship.review $observed -Bytes)
    if ($request.relationship.kind -ceq 'same-source') {
        Assert-SourceDelivery ($request.source_reference.commit -ceq $request.publication_subject.candidate_commit -and $request.source_reference.tree -ceq $request.publication_subject.candidate_tree) 'Same-source relationship is false.'
    }
    if($Request.consumer.boundary_kind -ceq 'accepted-source-owner') {
        Assert-SourceDelivery ($null -eq $Request.source_package -and $Request.relationship.kind -ceq 'same-source') 'Accepted source-owner authority cannot transfer to another source subject or FAST package.'
        return
    }
    $package = Read-SourceDeliveryReference $request.source_package $observed
    $assessment = & (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/Test-DirectWorkPackage.ps1') -Path $request.source_package.path | ConvertFrom-Json
    Assert-SourceDelivery ($assessment.direct_execution_allowed -eq $true -and $assessment.minimum_guard_profile -ceq 'fast') 'Source package requires its own locked/labs owner; disposition cannot downgrade it.'
    $rows = @($package.repositories | Where-Object repository -CEQ $request.publication_subject.repository)
    Assert-SourceDelivery ($rows.Count -eq 1 -and $rows[0].base_commit -ceq $request.publication_subject.base_commit) 'Source package base differs.'
    foreach ($path in @($request.publication_subject.allowed_paths)) { Assert-SourceDelivery (Test-SourceOnlyInputPathAllowed $path @($rows[0].allowed_paths)) 'Source package does not authorize publication scope.' }
}

function New-MorphospaceSourceDeliveryDisposition {
    [CmdletBinding()]
    param([string]$RequestPath,[string]$ExpectedRequestSha256,[string]$WorkspaceRoot,[string]$RepoMapPath,[string]$HumanDecisionPath,[string]$ExpectedHumanDecisionSha256,[string]$OutPath)
    $observed = New-SourceDeliveryObservation; $request = Read-SourceDeliveryDocument $RequestPath $ExpectedRequestSha256 'request' $observed
    # A recorded decision is an explicit human attestation, never a new grant.
    Assert-SourceDelivery ($request.ordering_supersession.human_decision.path -ceq [IO.Path]::GetFullPath($HumanDecisionPath) -and $request.ordering_supersession.human_decision.sha256 -ceq $ExpectedHumanDecisionSha256) 'Human decision must be separately pinned by the invoking authority.'
    [void](Read-SourceDeliveryReference $request.ordering_supersession.human_decision $observed -Bytes)
    $proof = Get-SourceDeliveryFrozenConsumer $WorkspaceRoot $request -Creating -Observed $observed
    Assert-SourceDeliveryImmutableRequest $request $proof.original_unit $observed
    Assert-SourceDelivery ([IO.Path]::GetFullPath($RepoMapPath) -ceq [IO.Path]::GetFullPath($request.publication_map.path)) 'Publication map locator differs.'
    $map = Read-SourceDeliveryReference $request.publication_map $observed; $root = Get-SourceDeliveryRepository $request.publication_subject $map
    Assert-SourceDelivery ((Get-SourceOnlyInputGitValue $root @('rev-parse','HEAD') 'Source HEAD') -ceq $request.publication_subject.candidate_commit -and @((Invoke-SourceOnlyInputGit $root @('status','--porcelain=v1','--untracked-files=all')).lines).Count -eq 0) 'Publication checkout is not the clean subject.'
    $document = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_delivery_disposition.v1';kind='disposition';request=$request;request_reference=Get-SourceDeliveryReference $RequestPath;adoption_pending=$true;source_landed=$false;acceptance_credit=$false}
    Assert-SourceDeliveryObservation $observed
    [void](Get-SourceDeliveryFrozenConsumer $WorkspaceRoot $request -Creating -Observed $observed)
    Assert-SourceDeliveryCheckout $root $request.publication_subject
    Write-SourceOnlyInputDocument $document $OutPath
}

function Read-SourceDeliveryOriginal($Reference,[Collections.IDictionary]$Observed) {
    $c = Read-SourceDeliveryReference $Reference $Observed
    Assert-MorphospaceExactPropertySet $c @('schema','exit_code','genuine_full_eof','raw_capture_complete','process_reaped','finished_utc','intent','stdout','stderr','streams','observer_errors','termination_requested','automatic_retry') @() 'Original completion'
    Assert-SourceDelivery ($c.exit_code -is [int] -or $c.exit_code -is [long]) 'Original exit code must be an integer.'
    Assert-SourceDelivery ($c.schema -ceq 'task.root.command_capture_completion.v2' -and $c.exit_code -eq 0 -and $c.genuine_full_eof -eq $true -and $c.raw_capture_complete -eq $true -and $c.process_reaped -eq $true -and $c.termination_requested -eq $false -and $c.automatic_retry -eq $false -and @($c.observer_errors).Count -eq 0) 'Original did not close successfully with complete terminal streams.'
    $intent = Read-SourceDeliveryReference $c.intent $Observed
    Assert-MorphospaceExactPropertySet $intent @('schema','argv','cwd','started_utc','no_timeout_or_retry','capture_source') @() 'Original capture intent'
    [void](Read-SourceDeliveryReference $intent.capture_source $Observed -Bytes)
    Assert-MorphospaceExactPropertySet $c.streams @('stdout','stderr') @() 'Original stream set'
    Assert-SourceDelivery ($intent.schema -ceq 'task.root.command_capture_intent.v2' -and $intent.no_timeout_or_retry -is [bool] -and $intent.no_timeout_or_retry -eq $true -and $intent.argv -is [array] -and @($intent.argv).Count -gt 0 -and @($intent.argv|Where-Object{$_ -isnot [string] -or -not $_}).Count -eq 0) 'Original intent policy differs.'
    foreach ($name in @('stdout','stderr')) {
        Assert-MorphospaceExactPropertySet $c.$name @('path','sha256','bytes') @() 'Original raw stream'
        Assert-SourceDelivery (($c.$name.bytes -is [int] -or $c.$name.bytes -is [long]) -and $c.$name.bytes -ge 0) 'Original stream byte length must be a nonnegative integer.'
        [void](Read-SourceDeliveryReference $c.$name $Observed -Bytes)
        $s=$c.streams.$name
        Assert-MorphospaceExactPropertySet $s @('raw','eof','drained_bytes','stored_bytes','raw_capture_complete','storage_error','read_error') @() 'Original terminal stream'
        Assert-SourceDelivery ($s.eof -is [bool] -and $s.eof -eq $true -and $s.raw_capture_complete -is [bool] -and $s.raw_capture_complete -eq $true -and ($s.drained_bytes -is [int] -or $s.drained_bytes -is [long]) -and ($s.stored_bytes -is [int] -or $s.stored_bytes -is [long]) -and $null -eq $s.storage_error -and $null -eq $s.read_error -and $s.drained_bytes -eq $c.$name.bytes -and $s.stored_bytes -eq $c.$name.bytes -and (ConvertTo-MorphospaceCanonicalJson $s.raw) -ceq (ConvertTo-MorphospaceCanonicalJson $c.$name)) 'Original terminal stream join differs.'
    }
    foreach($name in @('genuine_full_eof','raw_capture_complete','process_reaped','termination_requested','automatic_retry')) { Assert-SourceDelivery ($c.$name -is [bool]) 'Original terminal flags must be Boolean.' }
    $started=[DateTimeOffset]::MinValue;$finished=[DateTimeOffset]::MinValue
    Assert-SourceDelivery ($intent.started_utc -is [string] -and $c.finished_utc -is [string] -and [DateTimeOffset]::TryParse($intent.started_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$started) -and [DateTimeOffset]::TryParse($c.finished_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$finished) -and $finished -ge $started) 'Original capture interval is invalid or reversed.'
    [pscustomobject]@{completion=$c;intent=$intent}
}

function Read-SourceDeliveryProvider($Reference,[string[]]$Arguments,[Collections.IDictionary]$Observed) {
    $original = Read-SourceDeliveryOriginal $Reference $Observed
    Assert-SourceDelivery ((ConvertTo-MorphospaceCanonicalJson @($original.intent.argv|Select-Object -Skip 1)) -ceq (ConvertTo-MorphospaceCanonicalJson $Arguments)) 'Provider argv differs from exact read-only request.'
    $raw = [IO.File]::ReadAllBytes([string]$original.completion.stdout.path)
    # Hash-checked provider transport legitimately contains top-level arrays.
    [Text.UTF8Encoding]::new($false,$true).GetString($raw) | ConvertFrom-Json -Depth 100 -DateKind String -NoEnumerate
}

function Assert-SourceDeliveryFixedQueryArguments([string[]]$Argv,[string]$Root) {
    $expected=@('--no-optional-locks','--no-pager','--no-replace-objects','-C',$Root,'status','--porcelain=v2','--branch','--untracked-files=all')
    $actual=@($Argv|Select-Object -Skip 1)
    Assert-SourceDelivery ($actual.Count -eq $expected.Count -and [IO.Path]::IsPathFullyQualified([string]$actual[4])) 'Source observation is not the fixed clean-head Git query.'
    $comparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    $observedRoot=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$actual[4]))
    $expectedRoot=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Root))
    Assert-SourceDelivery ($comparer.Equals($observedRoot,$expectedRoot)) 'Source observation is not the fixed clean-head Git query.'
    # Normalize only the fixed -C directory; every other argument remains exact.
    $actual[4]=$expected[4]
    Assert-SourceDelivery ((ConvertTo-MorphospaceCanonicalJson $actual) -ceq (ConvertTo-MorphospaceCanonicalJson $expected)) 'Source observation is not the fixed clean-head Git query.'
}

function Get-SourceDeliveryLandingProof($Request,[Collections.IDictionary]$Observed,$Map,[switch]$Observe) {
    $disposition = Read-SourceDeliveryDocument $Request.disposition.path $Request.disposition.sha256 'disposition' $Observed
    $d = $disposition.request; $s=$d.publication_subject
    $originalRequest=Read-SourceDeliveryDocument $disposition.request_reference.path $disposition.request_reference.sha256 'request' $Observed
    Assert-SourceDelivery ((ConvertTo-MorphospaceCanonicalJson $d) -ceq (ConvertTo-MorphospaceCanonicalJson $originalRequest)) 'Disposition request bytes and embedded request differ.'
    $consumerProof=Get-SourceDeliveryFrozenConsumer $d.consumer.workspace_root $d -Observed $Observed
    Assert-SourceDeliveryImmutableRequest $d $consumerProof.original_unit $Observed
    [void](Read-SourceDeliveryReference $d.ordering_supersession.human_decision $Observed -Bytes)
    [void](Read-SourceDeliveryReference $d.relationship.review $Observed -Bytes)
    [void](Read-SourceDeliveryReference $Request.source_review $Observed -Bytes)
    $publicationMap = Read-SourceDeliveryReference $d.publication_map $Observed
    $root = Get-SourceDeliveryRepository $s $publicationMap
    $provider = Get-SourceDeliveryReference $Request.provider.path
    Assert-SourceDelivery ($provider.sha256 -ceq $Request.provider.sha256) 'Qualified provider executable drifted.'
    [void](Read-SourceDeliveryReference $Request.provider $Observed -Bytes)
    [void](Read-SourceDeliveryReference $Request.source_git $Observed -Bytes)
    $before=Read-SourceDeliveryOriginal $Request.source_before_original $Observed
    $after=Read-SourceDeliveryOriginal $Request.source_after_original $Observed
    foreach($snapshot in @($before,$after)) {
        Assert-SourceDeliveryFixedQueryArguments @($snapshot.intent.argv) $root
        Assert-SourceDelivery ([IO.Path]::GetFullPath([string]$snapshot.intent.argv[0]) -ceq [IO.Path]::GetFullPath($Request.source_git_invocation_path)) 'Original source Git executable identity differs.'
        $lines=@([IO.File]::ReadAllLines($snapshot.completion.stdout.path))
        Assert-SourceDelivery (@($lines|Where-Object {$_ -ceq "# branch.oid $($s.candidate_commit)"}).Count -eq 1 -and @($lines|Where-Object {$_ -and -not $_.StartsWith('# ')}).Count -eq 0) 'Source observation is dirty or names another head.'
    }
    $begin=[DateTimeOffset]::Parse($before.completion.finished_utc,[Globalization.CultureInfo]::InvariantCulture)
    $end=[DateTimeOffset]::Parse($after.intent.started_utc,[Globalization.CultureInfo]::InvariantCulture)
    Assert-SourceDelivery ($end -ge $begin) 'Source observation interval is reversed.'
    Assert-SourceDelivery (@($Request.source_checks).Count -eq @($d.source_check_commands).Count) 'Source checks are incomplete.'
    for ($i=0;$i -lt @($Request.source_checks).Count;$i++) {
        $check = Read-SourceDeliveryOriginal $Request.source_checks[$i] $Observed
        Assert-SourceDelivery ((ConvertTo-MorphospaceCanonicalJson @($check.intent.argv)) -ceq (ConvertTo-MorphospaceCanonicalJson @($d.source_check_commands[$i])) -and [IO.Path]::GetFullPath([string]$check.intent.cwd) -ceq $root) 'Source check command or executing checkout differs.'
        Assert-SourceDelivery ([DateTimeOffset]::Parse($check.intent.started_utc,[Globalization.CultureInfo]::InvariantCulture) -ge $begin -and [DateTimeOffset]::Parse($check.completion.finished_utc,[Globalization.CultureInfo]::InvariantCulture) -le $end) 'Source check is outside the clean subject observation interval.'
    }
    $endpoint="repos/$($s.repository)/pulls/$($Request.pull_request_number)"
    $pr=Read-SourceDeliveryProvider $Request.pull_request_original @('api','--method','GET',$endpoint) $Observed
    Assert-SourceDelivery ($pr.number -eq $Request.pull_request_number -and $pr.state -ceq 'closed' -and $pr.merged -eq $true -and $pr.head.sha -ceq $s.candidate_commit -and $pr.base.ref -ceq 'main' -and $pr.base.repo.full_name -ceq $s.repository -and $pr.head.repo.full_name -ceq $s.repository) 'Merged PR subject/repository/target differs.'
    $checks=Read-SourceDeliveryProvider $Request.required_checks_original @('pr','checks',[string]$Request.pull_request_number,'--repo',$s.repository,'--required','--json','name,state,link') $Observed
    Assert-SourceDelivery (@($checks).Count -gt 0 -and @($checks|Where-Object { $_.state -cne 'SUCCESS' -or -not $_.name -or -not $_.link }).Count -eq 0) 'Actual required checks are not all successful.'
    $operation=Read-SourceDeliveryOriginal $Request.merge_original $Observed
    $requiredOriginal=Read-SourceDeliveryOriginal $Request.required_checks_original $Observed
    $prOriginal=Read-SourceDeliveryOriginal $Request.pull_request_original $Observed
    foreach($original in @($operation,$requiredOriginal,$prOriginal)) { Assert-SourceDelivery ([IO.Path]::GetFullPath([string]$original.intent.argv[0]) -ceq [IO.Path]::GetFullPath($Request.provider_invocation_path)) 'Provider executable identity differs.' }
    Assert-SourceDelivery ([DateTimeOffset]::Parse($requiredOriginal.intent.started_utc,[Globalization.CultureInfo]::InvariantCulture) -ge [DateTimeOffset]::Parse($pr.merged_at,[Globalization.CultureInfo]::InvariantCulture) -and [DateTimeOffset]::Parse($prOriginal.intent.started_utc,[Globalization.CultureInfo]::InvariantCulture) -ge [DateTimeOffset]::Parse($requiredOriginal.completion.finished_utc,[Globalization.CultureInfo]::InvariantCulture)) 'Required-check readback must follow the actual merge and precede the final exact PR readback.'
    Assert-SourceDelivery ((ConvertTo-MorphospaceCanonicalJson @($operation.intent.argv|Select-Object -Skip 1)) -ceq (ConvertTo-MorphospaceCanonicalJson @('pr','merge',[string]$Request.pull_request_number,'--repo',$s.repository,'--merge','--match-head-commit',$s.candidate_commit))) 'Normal merge command is not bound to the qualified subject.'
    $mergeTime=[DateTimeOffset]::Parse($pr.merged_at,[Globalization.CultureInfo]::InvariantCulture)
    $operationStart=[DateTimeOffset]::Parse($operation.intent.started_utc,[Globalization.CultureInfo]::InvariantCulture);$operationFinish=[DateTimeOffset]::Parse($operation.completion.finished_utc,[Globalization.CultureInfo]::InvariantCulture)
    Assert-SourceDelivery ($operationStart -ge [DateTimeOffset]::Parse($after.completion.finished_utc,[Globalization.CultureInfo]::InvariantCulture) -and $mergeTime.ToUnixTimeSeconds() -ge $operationStart.ToUnixTimeSeconds() -and $mergeTime.ToUnixTimeSeconds() -le $operationFinish.ToUnixTimeSeconds() -and [DateTimeOffset]::Parse($requiredOriginal.intent.started_utc,[Globalization.CultureInfo]::InvariantCulture) -ge $operationFinish) 'Source checks, actual merge and required-check readback chronology differ.'
    $merge=[string]$pr.merge_commit_sha
    Assert-SourceDelivery ($merge -cmatch '^[0-9a-f]{40}$' -and (Get-SourceOnlyInputGitValue $root @('rev-list','--parents','-n','1',$merge) 'Merge parents') -ceq "$merge $($s.base_commit) $($s.candidate_commit)" -and (Get-SourceOnlyInputGitValue $root @('rev-parse',"$merge^{tree}") 'Merge tree') -ceq $s.candidate_tree) 'Ordinary two-parent merge/tree differs.'
    if ($Observe) {
        $git=Get-SourceOnlyInputGit
        Assert-SourceDelivery ([IO.Path]::GetFullPath($git.path) -ceq [IO.Path]::GetFullPath($Request.source_git_invocation_path) -and $git.sha256 -ceq $Request.source_git.sha256 -and (Get-MorphospaceFileSha256 $Request.provider_invocation_path) -ceq $Request.provider.sha256) 'Observed original executable pins differ from retained evidence bytes.'
        Assert-SourceDelivery ((Get-SourceOnlyInputGitValue $root @('rev-parse','HEAD') 'Source HEAD') -ceq $s.candidate_commit -and @((Invoke-SourceOnlyInputGit $root @('status','--porcelain=v1','--untracked-files=all')).lines).Count -eq 0) 'Publication checkout drifted.'
        $remote=Get-SourceOnlyInputGitValue $root @('remote','get-url','origin') 'Source remote'
        $readback=Get-SourceOnlyInputRemoteReadback $root $remote 'main'
        Assert-SourceDelivery ($readback.status -ceq 'observed' -and (Invoke-SourceOnlyInputGit $root @('merge-base','--is-ancestor',$merge,$readback.revision) -AllowFailure).exit_code -eq 0) 'Fresh remote does not retain the actual merge.'
    }
    return [pscustomobject]@{disposition=$disposition;merge_commit=$merge;merge_tree=$s.candidate_tree;source_reference=$d.source_reference;publication_subject=$s;relationship=$d.relationship}
}

function New-MorphospaceSourceDeliveryLanding {
    [CmdletBinding()]
    param([string]$RequestPath,[string]$ExpectedRequestSha256,[string]$RepoMapPath,[string]$OutPath)
    $observed=New-SourceDeliveryObservation; $request=Read-SourceDeliveryDocument $RequestPath $ExpectedRequestSha256 'landing-request' $observed
    $map=Read-MorphospaceProtocolJson $RepoMapPath
    Assert-SourceDelivery ([IO.Path]::GetFullPath($RepoMapPath) -ceq [IO.Path]::GetFullPath((Read-SourceDeliveryDocument $request.disposition.path $request.disposition.sha256 'disposition' $observed).request.publication_map.path)) 'Landing observation map locator differs.'
    $proof=Get-SourceDeliveryLandingProof $request $observed $map -Observe
    $doc=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.source_delivery_disposition.v1';kind='landing';request=$request;request_reference=Get-SourceDeliveryReference $RequestPath;merge_commit=$proof.merge_commit;merge_tree=$proof.merge_tree;adoption_pending=$true;source_landed=$true;acceptance_credit=$false}
    Assert-SourceDeliveryObservation $observed
    $d=(Read-SourceDeliveryDocument $request.disposition.path $request.disposition.sha256 'disposition' $observed).request
    Assert-SourceDeliveryCheckout (Get-SourceDeliveryRepository $d.publication_subject $map) $d.publication_subject
    Write-SourceOnlyInputDocument $doc $OutPath
}

function Test-MorphospaceSourceDeliveryLanding {
    [CmdletBinding()]
    param([string]$LandingPath,[string]$ExpectedLandingSha256,[string]$WorkspaceRoot,[string]$UnitId,[object]$RepositoryMap)
    $observed=New-SourceDeliveryObservation; $landing=Read-SourceDeliveryDocument $LandingPath $ExpectedLandingSha256 'landing' $observed
    $originalRequest=Read-SourceDeliveryDocument $landing.request_reference.path $landing.request_reference.sha256 'landing-request' $observed
    Assert-SourceDelivery ((ConvertTo-MorphospaceCanonicalJson $landing.request) -ceq (ConvertTo-MorphospaceCanonicalJson $originalRequest)) 'Landing request bytes and embedded request differ.'
    $map=if($RepositoryMap -is [string]){Read-MorphospaceProtocolJson $RepositoryMap}elseif($RepositoryMap -is [hashtable]){[pscustomobject]@{repositories=@($RepositoryMap.Values)}}else{$RepositoryMap}
    $proof=Get-SourceDeliveryLandingProof $landing.request $observed $map
    Assert-SourceDelivery ($landing.merge_commit -ceq $proof.merge_commit -and $landing.merge_tree -ceq $proof.merge_tree -and $proof.disposition.request.consumer.unit_id -ceq $UnitId) 'Landed evidence subject differs.'
    Assert-SourceDelivery ([IO.Path]::GetFullPath($WorkspaceRoot) -ceq [IO.Path]::GetFullPath($proof.disposition.request.consumer.workspace_root)) 'Consumer workspace locator differs.'
    $originalMap=Read-SourceDeliveryReference $proof.disposition.request.consumer.repository_map $observed
    Assert-SourceDelivery (@($originalMap.repositories).Count -eq @($map.repositories).Count) 'Consumer map membership differs.'
    foreach($row in @($originalMap.repositories)) {
        $matches=@($map.repositories|Where-Object {[string]$_.repo_id -ceq [string]$row.repo_id -and [string]$_.role -ceq [string]$row.role -and [IO.Path]::GetFullPath([string]$_.path) -ceq [IO.Path]::GetFullPath([string]$row.path)})
        Assert-SourceDelivery ($matches.Count -eq 1) 'Consumer map root differs.'
    }
    Assert-SourceDeliveryObservation $observed
    # This authenticates source delivery only. The caller retains every criterion,
    # gate, source, tooling, instruction, validation and acceptance predicate.
    return $true
}

Export-ModuleMember -Function `
    Get-MorphospaceSourceOnlyPublicationReadiness, New-MorphospaceSourceOnlyPublicationPlan, `
    Start-MorphospaceSourceOnlyPublicationOperation, Complete-MorphospaceSourceOnlyPublicationOperationObservation, `
    New-MorphospaceSourceOnlyPublicationExecution, New-MorphospaceSourceDeliveryDisposition, `
    New-MorphospaceSourceDeliveryLanding, Test-MorphospaceSourceDeliveryLanding
