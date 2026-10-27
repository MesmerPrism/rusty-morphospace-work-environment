Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:MorphospaceValidationReceiptSchemas = [ordered]@{
    'rusty.morphospace.workflow.validation_receipt.v1' = 'validation-receipt.schema.json'
    'rusty.morphospace.workflow.validation_receipt.v2' = 'validation-receipt-v2.schema.json'
}
$script:MorphospaceValidationReceiptPathComparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Copy-MorphospaceValidationReceiptValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
}

function Invoke-MorphospaceValidationReceiptGit {
    param([string]$RepositoryPath,[string[]]$Arguments,[switch]$AllowFailure)
    $observationModule = Get-Variable -Name MorphospaceValidationReceiptObservationModule -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $observationModule) {
        $observationModulePath = Join-Path $PSScriptRoot 'MorphospaceContentObservation.psm1'
        $expectedModulePath = [IO.Path]::GetFullPath($observationModulePath)
        $exactModule = @(Get-Module | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path).Equals($expectedModulePath,$script:MorphospaceValidationReceiptPathComparison) } | Select-Object -Last 1)
        if ($exactModule.Count -eq 0) {
            $exactModule = @(Import-Module $observationModulePath -PassThru -DisableNameChecking -Prefix ValidationReceiptDependency)
        }
        $script:MorphospaceValidationReceiptObservationModule = $exactModule[0]
        $observationModule = $script:MorphospaceValidationReceiptObservationModule
    }
    if ($null -eq (Get-Variable -Name MorphospaceValidationReceiptGit -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
        $script:MorphospaceValidationReceiptGit = & $observationModule { Get-MorphospaceBoundExecutable -Name git }
    }
    $result = & $observationModule {
        param($Executable,$ExecutableSha256,$Root,$GitArguments,$PermitFailure)
        Invoke-MorphospaceBoundGitBytes -GitExecutable $Executable -ExpectedExecutableSha256 $ExecutableSha256 -RepositoryPath $Root -Arguments $GitArguments -TimeoutSeconds 30 -MaxOutputBytes 1048576 -AllowFailure:$PermitFailure
    } $script:MorphospaceValidationReceiptGit.path $script:MorphospaceValidationReceiptGit.sha256 $RepositoryPath $Arguments $AllowFailure.IsPresent
    $utf8 = [Text.UTF8Encoding]::new($false,$true)
    try {
        $stdout = $utf8.GetString([byte[]]$result.stdout)
    } catch {
        throw 'Validation receipt Git observation emitted invalid UTF-8.'
    }
    $lines = if ($stdout.Length -eq 0) { @() } else { @($stdout.TrimEnd("`r","`n").Split("`n") | ForEach-Object { $_.TrimEnd("`r") }) }
    return [pscustomobject]@{ exit_code=[int]$result.exit_code; lines=@($lines); text=$stdout.Trim() }
}

function Test-MorphospaceValidationReceiptPathAllowed {
    param([string]$Path,[object[]]$AllowedPaths)
    foreach ($allowedRaw in @($AllowedPaths)) {
        $allowed = ([string]$allowedRaw).Replace('\','/').TrimEnd('/')
        if ($Path.Equals($allowed,[StringComparison]::Ordinal) -or $Path.StartsWith($allowed + '/', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Resolve-MorphospaceValidationReceiptWorkspacePath {
    param([string]$Workspace,[string]$RelativePath,[switch]$RequireLeaf)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Validation receipt authority path must be workspace-relative: $RelativePath" }
    $resolved = [IO.Path]::GetFullPath((Join-Path $Workspace $RelativePath))
    $workspacePrefix = $Workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($workspacePrefix,$script:MorphospaceValidationReceiptPathComparison)) { throw "Validation receipt authority path escapes the workspace: $RelativePath" }
    if ($RequireLeaf -and -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Validation receipt authority file does not exist: $RelativePath" }
    return $resolved
}

function Assert-MorphospaceValidationReceiptNoReparseAncestry {
    param([string]$Workspace,[string]$TargetPath)
    $workspaceRoot = [IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $target = [IO.Path]::GetFullPath($TargetPath)
    $workspacePrefix = $workspaceRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($workspacePrefix,$script:MorphospaceValidationReceiptPathComparison)) { throw 'Generated validation receipt must stay inside the project workspace.' }
    $parent = [IO.Path]::GetDirectoryName($target)
    if ($parent.Equals($workspaceRoot,$script:MorphospaceValidationReceiptPathComparison)) { return }
    $relativeParent = $parent.Substring($workspacePrefix.Length)
    $current = $workspaceRoot
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    foreach ($component in @($relativeParent.Split($separators,[StringSplitOptions]::RemoveEmptyEntries))) {
        $current = Join-Path $current $component
        if (-not (Test-Path -LiteralPath $current)) { break }
        if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Generated validation receipt path traverses a reparse point: $current" }
    }
}

function Get-MorphospaceValidationReceiptFileHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-MorphospaceValidationReceiptStructure {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')][string]$ReceiptPath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Document')][object]$Document,
        [string[]]$AllowedSchemaIds = @($script:MorphospaceValidationReceiptSchemas.Keys)
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
            throw "Validation receipt does not exist: $ReceiptPath"
        }
        $json = Get-Content -LiteralPath $ReceiptPath -Raw
    } else {
        $json = $Document | ConvertTo-Json -Depth 100
    }

    try {
        $receipt = $json | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    } catch {
        throw "Validation receipt is not valid JSON: $($_.Exception.Message)"
    }

    $schemaId = if ($receipt.PSObject.Properties.Name -contains 'schema') { [string]$receipt.schema } else { '' }
    if (-not $script:MorphospaceValidationReceiptSchemas.Contains($schemaId)) {
        throw "Validation receipt has an unsupported schema ID '$schemaId'."
    }
    if (@($AllowedSchemaIds | Where-Object { [string]$_ -ceq $schemaId }).Count -ne 1) {
        throw "Validation receipt schema '$schemaId' is not allowed by this workflow stage."
    }

    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $schemaPath = Join-Path $repositoryRoot "schemas\$($script:MorphospaceValidationReceiptSchemas[$schemaId])"
    $schemaErrors = @()
    try {
        # A failed oneOf branch can be reported before the actual invalid field.
        # Retain the complete result and bounded diagnostics from this same check.
        $valid = Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    } catch {
        throw "Validation receipt does not satisfy structural schema '$schemaId': $($_.Exception.Message)"
    }
    if (-not $valid) {
        $messages = [Collections.Generic.List[string]]::new()
        foreach ($schemaError in $schemaErrors) { $messages.Add($schemaError.Exception.Message) }
        # PowerShell 7.6.7 can return false without reporting nested errors.
        # Upstream reproduction: PowerShell/PowerShell issue #28218.
        # Traverse the same bundled schema engine's hierarchy for diagnostics
        # only. The original false result remains the rejection decision even
        # if diagnostic extraction fails or a second evaluation disagrees.
        try {
            $options = [Json.Schema.EvaluationOptions]::new()
            $options.OutputFormat = [Json.Schema.OutputFormat]::Hierarchical
            $options.SchemaRegistry.Fetch = $null
            $schemaText = Get-Content -LiteralPath $schemaPath -Raw
            $evaluation = [Json.Schema.JsonSchema]::FromText($schemaText).Evaluate([Text.Json.Nodes.JsonNode]::Parse($json), $options)
            $queue = [Collections.Generic.Queue[object]]::new()
            $queue.Enqueue($evaluation)
            $diagnosticLength = 0
            while ($queue.Count -gt 0 -and $diagnosticLength -lt 4096) {
                $node = $queue.Dequeue()
                if (-not $node.IsValid -and $null -ne $node.Errors) {
                    foreach ($entry in $node.Errors.GetEnumerator()) {
                        $message = "at '$($node.InstanceLocation.ToString())': $($entry.Key): $($entry.Value)"
                        $messages.Add($message)
                        $diagnosticLength += $message.Length
                    }
                }
                if ($null -ne $node.Details) { foreach ($child in $node.Details) { $queue.Enqueue($child) } }
            }
            if ($queue.Count -gt 0) { $messages.Add('[nested diagnostics truncated]') }
        } catch {
            $messages.Add('Nested schema diagnostics unavailable; the original validation result is false.')
        }
        $details = @($messages.ToArray() | Select-Object -Unique) -join ' | '
        if ($details.Length -gt 4096) { $details = $details.Substring(0,4096) + ' [truncated]' }
        throw "Validation receipt does not satisfy structural schema '$schemaId': $details"
    }
    return $receipt
}

function Assert-MorphospaceNonpassNativePath {
    param([string]$Path)
    # Reject Win32 aliases (ADS, device namespaces, trailing dots/spaces) before
    # any filesystem observation. Origins may contain ordinary relative '..'.
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) { throw 'NONPASS custody does not support UNC or device namespaces.' }
    $rawRoot=[IO.Path]::GetPathRoot($Path)
    foreach($component in @($Path.Substring($rawRoot.Length).Split([char[]]@('\','/'),[StringSplitOptions]::RemoveEmptyEntries))){
        if($component -cin @('.','..')){continue}
        if ($component -match '[:*?]' -or $component -match '[. ]$' -or $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'NONPASS custody path contains a namespace alias.' }
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\') -or $full.StartsWith('//')) { throw 'NONPASS custody does not support UNC or device namespaces.' }
    $root = [IO.Path]::GetPathRoot($full)
    foreach ($component in @($full.Substring($root.Length).Split([char[]]@('\','/'),[StringSplitOptions]::RemoveEmptyEntries))) {
        if ($component -match '[:*?]' -or $component -match '[. ]$' -or $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'NONPASS custody path contains a namespace alias.' }
    }
    $current=$full
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "NONPASS custody path traverses a reparse point: $current" }
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }; $current=$parent
    }
    return $full
}

function Get-MorphospaceNonpassStorageRepository {
    param([string]$Workspace)
    # Source maps need not include the repository that owns ignored workspace
    # storage. Observe that containing owner independently, with bound Git.
    $root=Assert-MorphospaceNonpassNativePath ((Invoke-MorphospaceValidationReceiptGit $Workspace @('rev-parse','--show-toplevel')).text)
    if (-not $Workspace.Equals($root,$script:MorphospaceValidationReceiptPathComparison) -and -not $Workspace.StartsWith($root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,$script:MorphospaceValidationReceiptPathComparison)) { throw 'NONPASS custody Git storage owner does not contain the workspace.' }
    return $root
}

function Assert-MorphospaceNonpassStorage {
    param([string]$Workspace,[string]$Repository,[string[]]$Paths)
    foreach ($path in $Paths) {
        $full=Assert-MorphospaceNonpassNativePath $path
        Assert-MorphospaceValidationReceiptNoReparseAncestry $Workspace $full
        $relative=[IO.Path]::GetRelativePath($Repository,$full).Replace('\','/')
        if ($relative.StartsWith('../') -or $relative -eq '..' -or $relative -match '(^|/)\.git(/|$)') { throw 'NONPASS custody storage escapes planning ownership.' }
        $ignorePath=if($relative.EndsWith('-evidence')){$relative+'/'}else{$relative}
        # check-ignore rejects Git's literal pathspec magic; these generated
        # namespace paths have no wildcard characters and remain explicit.
        if ((Invoke-MorphospaceValidationReceiptGit $Repository @('--no-literal-pathspecs','check-ignore','--quiet','--no-index','--',$ignorePath) -AllowFailure).exit_code -ne 0) { throw "NONPASS custody storage must already be Git ignored: $ignorePath" }
        $tracked=Invoke-MorphospaceValidationReceiptGit $Repository @('ls-files','--',$relative)
        if ($tracked.text.Length -ne 0) { throw 'NONPASS custody storage must be untracked.' }
    }
}

function Get-MorphospaceNonpassStreamIdentity {
    param([IO.Stream]$Stream)
    $Stream.Position=0
    $hash=[Security.Cryptography.SHA256]::HashData($Stream)
    return [pscustomobject]@{ sha256=[Convert]::ToHexString($hash).ToLowerInvariant(); byte_length=$Stream.Length }
}

function Assert-MorphospaceNonpassSnapshotHandle {
    param([IO.FileStream]$Stream)
    # Reparse checks do not detect hard links. Existing exact bytes must also
    # be an independent leaf, or later editing an origin could mutate custody.
    if (-not ('Morphospace.NonpassCustodyV1.NativeFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Morphospace.NonpassCustodyV1 {
  public static class NativeFile {
    [StructLayout(LayoutKind.Sequential)] struct FileInfo {
      public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh,
        WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfo info);
    [DllImport("libc", EntryPoint="fstat", SetLastError=true)]
    static extern int FStat(int descriptor, IntPtr status);
    public static ulong LinkCount(SafeFileHandle file) {
      if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) {
        FileInfo info;
        if (!GetFileInformationByHandle(file, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return info.Links;
      }
      bool linux=RuntimeInformation.IsOSPlatform(OSPlatform.Linux);
      bool mac=RuntimeInformation.IsOSPlatform(OSPlatform.OSX);
      Architecture arch=RuntimeInformation.ProcessArchitecture;
      if ((!linux && !mac) || (arch!=Architecture.X64 && arch!=Architecture.Arm64))
        throw new PlatformNotSupportedException("NONPASS custody requires a supported stable file link-count observation.");
      IntPtr buffer=Marshal.AllocHGlobal(512);
      try {
        if (FStat(file.DangerousGetHandle().ToInt32(),buffer)!=0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if(mac) return (ushort)Marshal.ReadInt16(buffer,6);
        if(arch==Architecture.Arm64) return (uint)Marshal.ReadInt32(buffer,20);
        return (ulong)Marshal.ReadInt64(buffer,16);
      } finally { Marshal.FreeHGlobal(buffer); }
    }
  }
}
'@
    }
    if ([Morphospace.NonpassCustodyV1.NativeFile]::LinkCount($Stream.SafeFileHandle) -ne 1) { throw 'NONPASS custody snapshot or manifest is a hardlink alias.' }
}

function Assert-MorphospaceNonpassCustodyStructure {
    param([object]$Manifest)
    $schema=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'schemas/nonpass-evidence-custody-v1.schema.json'
    if (-not (Test-Json -Json ($Manifest|ConvertTo-Json -Depth 100) -SchemaFile $schema -ErrorAction Stop)) { throw 'NONPASS custody manifest does not satisfy its closed schema.' }
}

function Read-MorphospaceNonpassHeldProtocolJson {
    param([IO.Stream]$Stream,[string]$Context)
    $Stream.Position=0;$buffer=[IO.MemoryStream]::new()
    try {
        $Stream.CopyTo($buffer)
        $protocol=Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -PassThru -DisableNameChecking
        return &$protocol {param($bytes,$label)ConvertFrom-MorphospaceProtocolJsonBytes -Bytes $bytes -Context $label} ([byte[]]$buffer.ToArray()) $Context
    } finally { $buffer.Dispose() }
}

function Assert-MorphospaceNonpassEvidenceSnapshotBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ReceiptPath,[Parameter(Mandatory)][object]$Receipt,[Parameter(Mandatory)][object]$Artifact,[Parameter(Mandatory)][string]$ExpectedOriginPath,[Parameter(Mandatory)][string]$ExpectedOriginSha256)
    if ([string]$Receipt.schema -cne 'rusty.morphospace.workflow.validation_receipt.v1' -or [string]$Receipt.result -cnotin @('fail','partial','blocked')) { throw 'NONPASS custody cannot grant PASS or other receipt authority.' }
    $null=Assert-MorphospaceValidationReceiptStructure -Document $Receipt
    $workspace=Assert-MorphospaceNonpassNativePath $WorkspaceRoot
    $actualReceipt=Assert-MorphospaceNonpassNativePath $ReceiptPath
    if (-not ([IO.Path]::GetDirectoryName($actualReceipt)).Equals((Join-Path $workspace 'receipts'),$script:MorphospaceValidationReceiptPathComparison)) { throw 'NONPASS custody receipt must be a direct receipts child.' }
    $handles=[Collections.Generic.List[IO.Stream]]::new()
    try {
    $reserved=@($Receipt.artifacts|Where-Object { [string]$_.artifact_id -ceq 'nonpass-evidence-custody' -or [string]$_.kind -ceq 'nonpass-evidence-custody' })
    $namespace="receipts/$($Receipt.receipt_id)-evidence"
    if ($reserved.Count -ne 1 -or [string]$reserved[0].artifact_id -cne 'nonpass-evidence-custody' -or [string]$reserved[0].kind -cne 'nonpass-evidence-custody' -or [string]$reserved[0].path -cne "$($Receipt.receipt_id)-evidence/custody.json") { throw 'NONPASS custody reserved manifest binding is invalid.' }
    $manifestPath=Assert-MorphospaceNonpassNativePath (Join-Path $workspace "$namespace/custody.json")
    $planning=Get-MorphospaceNonpassStorageRepository $workspace
    Assert-MorphospaceNonpassStorage $workspace $planning @((Join-Path $workspace $namespace),$manifestPath)
    $manifestStream=[IO.File]::Open($manifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$handles.Add($manifestStream)
    Assert-MorphospaceNonpassSnapshotHandle $manifestStream
    if ((Get-MorphospaceNonpassStreamIdentity $manifestStream).sha256 -cne [string]$reserved[0].sha256) { throw 'NONPASS custody manifest raw hash drifted.' }
    $manifest=Read-MorphospaceNonpassHeldProtocolJson $manifestStream 'NONPASS custody manifest'
    Assert-MorphospaceNonpassCustodyStructure $manifest
    if ([string]$manifest.project_id -cne [string]$Receipt.project_id -or [string]$manifest.unit_id -cne [string]$Receipt.unit_id -or [string]$manifest.receipt_id -cne [string]$Receipt.receipt_id) { throw 'NONPASS custody receipt identity differs.' }
    $original=Assert-MorphospaceNonpassNativePath (Resolve-MorphospaceValidationReceiptWorkspacePath $workspace ([string]$manifest.receipt_path) -RequireLeaf)
    if (-not ([IO.Path]::GetDirectoryName($original)).Equals((Join-Path $workspace 'receipts'),$script:MorphospaceValidationReceiptPathComparison)) { throw 'NONPASS custody output namespace differs.' }
    # Retained Return copies are allowed only when their exact original bytes agree.
    $originalStream=[IO.File]::Open($original,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$handles.Add($originalStream)
    $receiptStream=[IO.File]::Open($actualReceipt,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$handles.Add($receiptStream)
    if ((Get-MorphospaceNonpassStreamIdentity $originalStream).sha256 -cne (Get-MorphospaceNonpassStreamIdentity $receiptStream).sha256) { throw 'NONPASS custody original output bytes differ.' }
    $actualDocument=Read-MorphospaceNonpassHeldProtocolJson $receiptStream 'NONPASS custody actual receipt'
    if (($actualDocument|ConvertTo-Json -Depth 100 -Compress) -cne ($Receipt|ConvertTo-Json -Depth 100 -Compress)) { throw 'NONPASS custody supplied receipt differs from actual bytes.' }
    $leaves=@($Receipt.artifacts|Where-Object artifact_id -CNE 'nonpass-evidence-custody')
    if ($leaves.Count -ne @($manifest.artifacts).Count) { throw 'NONPASS custody mapping is incomplete.' }
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $matched=[Collections.Generic.List[object]]::new()
    $expected=Assert-MorphospaceNonpassNativePath $ExpectedOriginPath
    for ($i=0;$i -lt $leaves.Count;$i++) {
        $leaf=$leaves[$i];$row=@($manifest.artifacts)[$i]
        $snapshot="$namespace/$('{0:d4}' -f $i)-$($leaf.artifact_id).bin"
        if (-not $ids.Add([string]$leaf.artifact_id) -or [string]$row.artifact_id -cne [string]$leaf.artifact_id -or [string]$row.kind -cne [string]$leaf.kind -or [string]$row.kind -ceq 'source-delivery-landing' -or [string]$row.snapshot_path -cne $snapshot -or [string]$leaf.path -cne $snapshot.Substring(9) -or [string]$row.sha256 -cne [string]$leaf.sha256) { throw 'NONPASS custody artifact mapping is invalid or ambiguous.' }
        $snapshotPath=Resolve-MorphospaceValidationReceiptWorkspacePath $workspace $snapshot -RequireLeaf
        Assert-MorphospaceNonpassStorage $workspace $planning @($snapshotPath)
        $stream=[IO.File]::Open($snapshotPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $handles.Add($stream);$identity=Get-MorphospaceNonpassStreamIdentity $stream
        Assert-MorphospaceNonpassSnapshotHandle $stream
        if ($identity.sha256 -cne [string]$row.sha256 -or $identity.byte_length -ne $row.byte_length) { throw 'NONPASS custody snapshot raw identity drifted.' }
        $originLocator=[string]$row.original_path
        $origin=Assert-MorphospaceNonpassNativePath $(if([IO.Path]::IsPathRooted($originLocator)){$originLocator}else{Join-Path ([IO.Path]::GetDirectoryName($original)) $originLocator})
        if ($origin.Equals($expected,$script:MorphospaceValidationReceiptPathComparison)) { $matched.Add($leaf) }
    }
    if ($matched.Count -gt 1) { throw 'NONPASS custody exact origin mapping is ambiguous.' }
    return ($matched.Count -eq 1 -and [string]$matched[0].sha256 -ceq $ExpectedOriginSha256 -and ($matched[0]|ConvertTo-Json -Compress) -ceq ($Artifact|ConvertTo-Json -Compress))
    } finally { foreach($handle in $handles){$handle.Dispose()} }
}

function New-MorphospaceNonpassEvidenceCustody {
    param([string]$Workspace,[string]$Output,[object]$Receipt,[object]$Owned)
    $directory=Join-Path $Workspace "receipts/$($Receipt.receipt_id)-evidence"
    $planning=Get-MorphospaceNonpassStorageRepository $Workspace
    $manifestPath=Join-Path $directory 'custody.json'
    $paths=@($directory,$manifestPath)+@(for($i=0;$i -lt $Receipt.artifacts.Count;$i++){Join-Path $directory ("$('{0:d4}' -f $i)-$($Receipt.artifacts[$i].artifact_id).bin")})
    Assert-MorphospaceNonpassStorage $Workspace $planning $paths
    if ([IO.Directory]::Exists($directory)) {
        foreach ($existing in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if ($existing.PSIsContainer -or @($paths|Where-Object { $_.Equals($existing.FullName,$script:MorphospaceValidationReceiptPathComparison) }).Count -ne 1) { throw 'NONPASS custody namespace contains unrelated existing bytes.' }
        }
    }
    $rows=[Collections.Generic.List[object]]::new()
    # Open and authenticate every explicit source before creating any destination.
    for ($i=0;$i -lt $Receipt.artifacts.Count;$i++) {
        $artifact=$Receipt.artifacts[$i]
        $originLocator=[string]$artifact.path
        $origin=Assert-MorphospaceNonpassNativePath $(if([IO.Path]::IsPathRooted($originLocator)){$originLocator}else{Join-Path ([IO.Path]::GetDirectoryName($Output)) $originLocator})
        if ($origin.Equals($Output,$script:MorphospaceValidationReceiptPathComparison) -or $origin.StartsWith($directory.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,$script:MorphospaceValidationReceiptPathComparison)) { throw 'NONPASS custody source aliases its output namespace.' }
        $stream=[IO.File]::Open($origin,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $Owned.handles.Add($stream)
        $identity=Get-MorphospaceNonpassStreamIdentity $stream
        if ($identity.sha256 -cne [string]$artifact.sha256) { throw 'NONPASS custody source changed during observation.' }
        $snapshot="receipts/$($Receipt.receipt_id)-evidence/$('{0:d4}' -f $i)-$($artifact.artifact_id).bin"
        $rows.Add([pscustomobject][ordered]@{artifact_id=$artifact.artifact_id;kind=$artifact.kind;original_path=$artifact.path;snapshot_path=$snapshot;sha256=$identity.sha256;byte_length=$identity.byte_length})
    }
    $manifest=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.nonpass_evidence_custody.v1';project_id=$Receipt.project_id;unit_id=$Receipt.unit_id;receipt_id=$Receipt.receipt_id;receipt_path=[IO.Path]::GetRelativePath($Workspace,$Output).Replace('\','/');artifacts=@($rows.ToArray())}
    Assert-MorphospaceNonpassCustodyStructure $manifest
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 100)+"`n")
    # Known namespace conflicts are ordinary no-write refusals. Hold every
    # existing exact leaf through publication, before creating any new path.
    foreach($row in $rows){
        $existingPath=Join-Path $Workspace $row.snapshot_path
        if([IO.File]::Exists($existingPath)){
            $existing=[IO.File]::Open($existingPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$Owned.handles.Add($existing)
            Assert-MorphospaceNonpassSnapshotHandle $existing
            $identity=Get-MorphospaceNonpassStreamIdentity $existing
            if($identity.sha256-cne$row.sha256-or$identity.byte_length-ne$row.byte_length){throw 'NONPASS custody existing snapshot conflicts before publication.'}
        }
    }
    if([IO.File]::Exists($manifestPath)){
        $existing=[IO.File]::Open($manifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$Owned.handles.Add($existing)
        Assert-MorphospaceNonpassSnapshotHandle $existing
        $identity=Get-MorphospaceNonpassStreamIdentity $existing
        if($identity.sha256-cne[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()-or$identity.byte_length-ne$bytes.Length){throw 'NONPASS custody existing manifest conflicts before publication.'}
    }
    if (-not [IO.Directory]::Exists($directory)) { $null=[IO.Directory]::CreateDirectory($directory);$Owned.directories.Add($directory) }
    for ($i=0;$i -lt $rows.Count;$i++) {
        $row=$rows[$i];$destination=Join-Path $Workspace $row.snapshot_path
        Assert-MorphospaceNonpassStorage $Workspace $planning @($destination)
        if (-not [IO.File]::Exists($destination)) {
            $target=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $Owned.files.Add($destination)
            try { $Owned.handles[$i].Position=0;$Owned.handles[$i].CopyTo($target);$target.Flush($true) } finally { $target.Dispose() }
        }
        $copy=[IO.File]::Open($destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $Owned.handles.Add($copy)
        Assert-MorphospaceNonpassSnapshotHandle $copy
        $actual=Get-MorphospaceNonpassStreamIdentity $copy
        if ($actual.sha256 -cne $row.sha256 -or $actual.byte_length -ne $row.byte_length) { throw 'NONPASS custody existing or copied snapshot conflicts.' }
        $Receipt.artifacts[$i].path=$row.snapshot_path.Substring(9)
    }
    if (-not [IO.File]::Exists($manifestPath)) {
        $target=[IO.File]::Open($manifestPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$Owned.files.Add($manifestPath)
        try { $target.Write($bytes);$target.Flush($true) } finally { $target.Dispose() }
    }
    $manifestHandle=[IO.File]::Open($manifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$Owned.handles.Add($manifestHandle)
    Assert-MorphospaceNonpassSnapshotHandle $manifestHandle
    $manifestIdentity=Get-MorphospaceNonpassStreamIdentity $manifestHandle
    if ($manifestIdentity.sha256 -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -or $manifestIdentity.byte_length -ne $bytes.Length) { throw 'NONPASS custody existing manifest conflicts.' }
    $Receipt.artifacts=@($Receipt.artifacts)+@([pscustomobject][ordered]@{artifact_id='nonpass-evidence-custody';kind='nonpass-evidence-custody';path="$($Receipt.receipt_id)-evidence/custody.json";sha256=$manifestIdentity.sha256})
    for ($i=0;$i -lt $rows.Count;$i++) {
        $identity=Get-MorphospaceNonpassStreamIdentity $Owned.handles[$i]
        if ($identity.sha256 -cne $rows[$i].sha256 -or $identity.byte_length -ne $rows[$i].byte_length) { throw 'NONPASS custody held source identity changed.' }
    }
    Assert-MorphospaceNonpassStorage $Workspace $planning $paths
}

function New-MorphospaceValidationReceiptV1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$RepoMapPath,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$OutPath,
        [string]$CreatedAt = ''
    )
    if ($UnitId -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') { throw 'Validation receipt generation UnitId is invalid.' }
    $workspace=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path).TrimEnd('\','/')
    $privateEvidence=Copy-MorphospaceValidationReceiptValue $Evidence
    $coreParameters=@{};foreach($key in $PSBoundParameters.Keys){$coreParameters[$key]=$PSBoundParameters[$key]};$coreParameters.Evidence=$privateEvidence
    $nonpass=($privateEvidence.PSObject.Properties.Name -contains 'result') -and [string]$privateEvidence.result -cin @('fail','partial','blocked')
    if (-not $nonpass) { return New-MorphospaceValidationReceiptV1Core @coreParameters }
    # All NONPASS calls acquire the existing owner lock before any unit or
    # eligibility observation. Core uses this one private evidence clone.
    $mutexModule=Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -PassThru -DisableNameChecking
    $guard=&$mutexModule {param($root)Enter-MorphospaceWorkspaceMutex $root} $workspace
    try { return New-MorphospaceValidationReceiptV1Core @coreParameters }
    finally { &$mutexModule {param($lock)Exit-MorphospaceWorkspaceMutex $lock} $guard }
}

function New-MorphospaceValidationReceiptV1Core {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][string]$RepoMapPath,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$OutPath,
        [string]$CreatedAt = ''
    )

    if ($UnitId -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') { throw 'Validation receipt generation UnitId is invalid.' }
    $workspace = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path).TrimEnd('\','/')
    $output = if ([IO.Path]::IsPathRooted($OutPath)) { [IO.Path]::GetFullPath($OutPath) } else { [IO.Path]::GetFullPath((Join-Path $workspace $OutPath)) }
    $workspacePrefix = $workspace + [IO.Path]::DirectorySeparatorChar
    if (-not $output.StartsWith($workspacePrefix,$script:MorphospaceValidationReceiptPathComparison)) { throw 'Generated validation receipt must stay inside the project workspace.' }
    Assert-MorphospaceValidationReceiptNoReparseAncestry $workspace $output
    if (Test-Path -LiteralPath $output) { throw "Generated validation receipt already exists: $output" }
    $outputDirectory = Split-Path -Parent $output

    $requiredEvidenceProperties = @('receipt_id','tier','result','artifacts','criteria','gates','device_validation')
    $actualEvidenceProperties = @($Evidence.PSObject.Properties.Name | Sort-Object)
    if (($requiredEvidenceProperties | Sort-Object) -join '|' -cne ($actualEvidenceProperties -join '|')) { throw 'Validation product evidence must contain exactly receipt_id, tier, result, artifacts, criteria, gates, and device_validation.' }
    if (@($Evidence.artifacts).Count -eq 0 -or @($Evidence.criteria).Count -eq 0 -or @($Evidence.gates).Count -eq 0) { throw 'Validation product evidence requires explicit artifacts, criteria, and gates.' }

    $projectPath = Join-Path $workspace 'project.spec.json'
    $unitPath = Join-Path $workspace "iteration-units\$UnitId.json"
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf) -or -not (Test-Path -LiteralPath $unitPath -PathType Leaf)) { throw 'Validation receipt generation requires the project and exact unit documents.' }
    $project = Get-Content -LiteralPath $projectPath -Raw | ConvertFrom-Json -Depth 100 -DateKind String
    $unit = Get-Content -LiteralPath $unitPath -Raw | ConvertFrom-Json -Depth 100 -DateKind String
    if ([string]$project.project_id -cne [string]$unit.project_id -or [string]$unit.unit_id -cne $UnitId) { throw 'Validation receipt generation project/unit identity does not match.' }

    $mapPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoMapPath).Path)
    $mapJson = Get-Content -LiteralPath $mapPath -Raw
    $mapSha256 = Get-MorphospaceValidationReceiptFileHash $mapPath
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not (Test-Json -Json $mapJson -SchemaFile (Join-Path $repositoryRoot 'schemas\repository-map.schema.json') -ErrorAction Stop)) { throw 'Validation receipt repository map does not satisfy its schema.' }
    $mapDocument = $mapJson | ConvertFrom-Json -Depth 100 -DateKind String
    $map = @{}
    foreach ($entry in @($mapDocument.repositories)) {
        if ($map.ContainsKey([string]$entry.repo_id)) { throw "Validation receipt repository map repeats '$([string]$entry.repo_id)'." }
        $map[[string]$entry.repo_id] = $entry
    }

    $baseByRepo = @{}
    $sourceLockPresent = $false
    $activeEnvelopeFiles = @{}
    $bootstrapAuthority = $null
    if (($unit.PSObject.Properties.Name -contains 'source_composition') -and $null -ne $unit.source_composition.lock_path) {
        $sourceLockPresent = $true
        $lockRelative = ([string]$unit.source_composition.lock_path).Replace('\','/')
        $lockPath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace $lockRelative -RequireLeaf
        $lockSha256 = Get-MorphospaceValidationReceiptFileHash $lockPath
        if (-not ($unit.PSObject.Properties.Name -contains 'candidate_freeze')) {
            try {
                Import-Module (Join-Path $PSScriptRoot 'MorphospaceBootstrapValidation.psm1') -DisableNameChecking
                $bootstrapAuthority = Get-MorphospaceBootstrapValidationAuthority -WorkspaceRoot $workspace -UnitId $UnitId -RepoMapPath $mapPath
            } catch {
                throw "Validation receipt generation requires the candidate-freeze binding unless bootstrap authority is authenticated: $($_.Exception.Message)"
            }
        } else {
        $freezeRelative = ([string]$unit.candidate_freeze.receipt_path).Replace('\','/')
        $freezePath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace $freezeRelative -RequireLeaf
        $freezeSha256 = Get-MorphospaceValidationReceiptFileHash $freezePath
        if ($freezeSha256 -cne [string]$unit.candidate_freeze.receipt_sha256) { throw 'Validation receipt candidate-freeze bytes do not match the unit binding.' }
        $freezeJson = Get-Content -LiteralPath $freezePath -Raw
        try { $freeze = $freezeJson | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop } catch { throw "Validation receipt candidate-freeze receipt is not valid JSON: $($_.Exception.Message)" }
        $freezeSchemas = @{
            'rusty.morphospace.workflow.candidate_freeze.v1'='candidate-freeze-v1.schema.json'
            'rusty.morphospace.workflow.candidate_freeze.v2'='candidate-freeze-v2.schema.json'
            'rusty.morphospace.workflow.candidate_freeze.v3'='candidate-freeze-v3.schema.json'
            'rusty.morphospace.workflow.candidate_freeze.v4'='candidate-freeze-v4.schema.json'
        }
        $freezeSchema = [string]$freeze.schema
        if (-not $freezeSchemas.ContainsKey($freezeSchema) -or -not (Test-Json -Json $freezeJson -SchemaFile (Join-Path $repositoryRoot "schemas\$($freezeSchemas[$freezeSchema])") -ErrorAction Stop)) { throw 'Validation receipt candidate-freeze receipt does not satisfy a supported schema.' }
        if ([string]$freeze.freeze_id -cne [string]$unit.candidate_freeze.freeze_id -or [string]$freeze.project_id -cne [string]$project.project_id -or [string]$freeze.unit_id -cne $UnitId) { throw 'Validation receipt candidate-freeze identity does not match the project and unit.' }
        $lockSha256 = Get-MorphospaceValidationReceiptFileHash $lockPath
        if ([string]$freeze.expected.source_composition_path -cne $lockRelative -or [string]$freeze.source_composition.path -cne $lockRelative -or [string]$freeze.expected.source_composition_sha256 -cne $lockSha256 -or [string]$freeze.source_composition.sha256 -cne $lockSha256) { throw 'Validation receipt source-composition lock does not match the candidate-freeze binding.' }
        $expectedMapPath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace ([string]$freeze.expected.repository_map_path) -RequireLeaf
        if (-not $expectedMapPath.Equals($mapPath,$script:MorphospaceValidationReceiptPathComparison) -or [string]$freeze.expected.repository_map_sha256 -cne $mapSha256) { throw 'Validation receipt repository map does not match the candidate-freeze binding.' }
        }

        $lockJson = Get-Content -LiteralPath $lockPath -Raw
        try { $lock = $lockJson | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop } catch { throw "Validation receipt source-composition lock is not valid JSON: $($_.Exception.Message)" }
        $lockSchemas = @{
            'rusty.morphospace.workflow.source_composition_lock.v1'='source-composition-lock.schema.json'
            'rusty.morphospace.workflow.development_envelope_source_composition.v1'='development-envelope-source-composition-v1.schema.json'
            'rusty.morphospace.workflow.development_envelope_source_composition.v2'='development-envelope-source-composition-v2.schema.json'
            'rusty.morphospace.workflow.development_envelope_source_composition.v3'='development-envelope-source-composition-v3.schema.json'
            'rusty.morphospace.workflow.active_development_envelope_source_composition.v1'='active-development-envelope-source-composition-v1.schema.json'
        }
        $lockSchema = [string]$lock.schema
        if (-not $lockSchemas.ContainsKey($lockSchema) -or -not (Test-Json -Json $lockJson -SchemaFile (Join-Path $repositoryRoot "schemas\$($lockSchemas[$lockSchema])") -ErrorAction Stop)) { throw 'Validation receipt source-composition lock does not satisfy a supported schema.' }
        if ([string]$lock.project_id -cne [string]$project.project_id -or (($lock.PSObject.Properties.Name -contains 'unit_id') -and [string]$lock.unit_id -cne $UnitId)) { throw 'Validation receipt source-composition identity does not match the project and unit.' }
        if ($lockSchema -ceq 'rusty.morphospace.workflow.active_development_envelope_source_composition.v1') {
            if ([string]$unit.status -cne 'validating') { throw 'Active-envelope validation receipt generation requires the validating unit.' }
            $statePath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace 'workspace.state.json' -RequireLeaf
            $featureLockPath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace 'feature.lock.json' -RequireLeaf
            $eventsPath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100 -DateKind String
            $featureLock = Get-Content -LiteralPath $featureLockPath -Raw | ConvertFrom-Json -Depth 100 -DateKind String
            if ([string]$state.current_unit -cne $UnitId -or [string]$state.project_id -cne [string]$project.project_id) { throw 'Active-envelope validation receipt generation requires its current project and unit.' }
            foreach ($path in @($projectPath,$unitPath,$statePath,$featureLockPath,$eventsPath,$lockPath,$mapPath,$freezePath)) {
                $activeEnvelopeFiles[$path] = Get-MorphospaceValidationReceiptFileHash $path
            }
            Import-Module (Join-Path $PSScriptRoot '../DevelopmentEnvelopeProvenance.psm1') -DisableNameChecking
            $envelope = Test-MorphospaceEffectiveDevelopmentEnvelope -WorkspaceRoot $workspace -UnitId $UnitId -RepositoryMapPath $mapPath
            # Resolve the canonical serializer in this function's scope after the
            # lineage reader loads its own static dependencies, without Force.
            Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1') -DisableNameChecking
            $effective = $envelope.effective
            $lockCanonicalSha256 = Get-MorphospaceCanonicalJsonSha256 $lock
            if ((Get-MorphospaceCanonicalJsonSha256 $effective.unit) -cne (Get-MorphospaceCanonicalJsonSha256 $unit) -or
                (Get-MorphospaceCanonicalJsonSha256 $effective.state) -cne (Get-MorphospaceCanonicalJsonSha256 $state) -or
                (Get-MorphospaceCanonicalJsonSha256 $effective.project) -cne (Get-MorphospaceCanonicalJsonSha256 $project) -or
                (Get-MorphospaceCanonicalJsonSha256 $effective.feature_lock) -cne (Get-MorphospaceCanonicalJsonSha256 $featureLock)) { throw 'Active-envelope validation receipt authority differs from its authenticated live lineage.' }
            if ([string]$effective.source_composition_binding.path -cne $lockRelative -or
                [string]$effective.source_composition_binding.raw_sha256 -cne $lockSha256 -or
                [string]$effective.source_composition_binding.canonical_sha256 -cne $lockCanonicalSha256 -or
                (Get-MorphospaceCanonicalJsonSha256 $effective.source_composition) -cne $lockCanonicalSha256) { throw 'Active-envelope validation receipt source is detached from its authenticated lineage.' }
            $effectiveMapPath = Resolve-MorphospaceValidationReceiptWorkspacePath $workspace ([string]$effective.repository_map.path) -RequireLeaf
            if (-not $effectiveMapPath.Equals($mapPath,$script:MorphospaceValidationReceiptPathComparison) -or
                [string]$effective.repository_map.raw_sha256 -cne $mapSha256) { throw 'Active-envelope validation receipt map is detached from its authenticated lineage.' }
        }
        Import-Module (Join-Path $PSScriptRoot 'MorphospaceSourceCompositionIdentity.psm1') -DisableNameChecking
        foreach ($row in @(Get-MorphospaceSourceCompositionRepositoryPins -Composition $lock)) {
            $repoId = [string]$row.repo_id
            if ($baseByRepo.ContainsKey($repoId)) { throw "Validation receipt source-composition lock repeats '$repoId'." }
            $baseByRepo[$repoId] = [string]$row.commit
        }
    }

    $repositoryRevisions = [Collections.Generic.List[object]]::new()
    $changedPaths = [Collections.Generic.List[object]]::new()
    foreach ($allowedRepository in @($unit.allowed_repositories)) {
        $repoId = [string]$allowedRepository.repo_id
        if (-not $map.ContainsKey($repoId)) { throw "Validation receipt generation lacks repository mapping '$repoId'." }
        $repositoryPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([string]$map[$repoId].path)).Path)
        $inside = Invoke-MorphospaceValidationReceiptGit $repositoryPath @('rev-parse','--is-inside-work-tree') -AllowFailure
        if ($inside.exit_code -ne 0 -or $inside.text -cne 'true') { throw "Generic v1 validation receipt generation requires mapped unit repositories to be Git worktrees; non-Git surfaces require a specialized receipt that binds their artifact coverage: '$repoId'." }
        $head = (Invoke-MorphospaceValidationReceiptGit $repositoryPath @('rev-parse','HEAD')).text
        $branchResult = Invoke-MorphospaceValidationReceiptGit $repositoryPath @('symbolic-ref','--quiet','--short','HEAD') -AllowFailure
        $branch = if ($branchResult.exit_code -eq 0) { $branchResult.text } else { $null }
        if ($sourceLockPresent -and -not $baseByRepo.ContainsKey($repoId)) { throw "Validation receipt source-composition lock lacks allowed repository '$repoId'." }
        $base = if ($baseByRepo.ContainsKey($repoId)) { [string]$baseByRepo[$repoId] } else {
            $upstream = Invoke-MorphospaceValidationReceiptGit $repositoryPath @('rev-parse','--verify','@{upstream}') -AllowFailure
            if ($upstream.exit_code -ne 0) { throw "Validation receipt generation requires an authenticated source-composition baseline or configured Git upstream for '$repoId'." }
            (Invoke-MorphospaceValidationReceiptGit $repositoryPath @('merge-base','HEAD','@{upstream}')).text
        }
        if ($base -cnotmatch '^[0-9a-f]{40}$' -or $head -cnotmatch '^[0-9a-f]{40}$') { throw "Validation receipt generation observed invalid Git identity for '$repoId'." }
        if ((Invoke-MorphospaceValidationReceiptGit $repositoryPath @('merge-base','--is-ancestor',$base,$head) -AllowFailure).exit_code -ne 0) { throw "Validation receipt baseline is not an ancestor of current HEAD for '$repoId'." }
        $repositoryRevisions.Add([pscustomobject][ordered]@{ repo_id=$repoId; base_revision=$base; head_revision=$head; branch=$branch }) | Out-Null

        $observedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($line in @((Invoke-MorphospaceValidationReceiptGit $repositoryPath @('-c','core.safecrlf=false','-c','core.autocrlf=false','diff','--name-only',$base,'--')).lines) + @((Invoke-MorphospaceValidationReceiptGit $repositoryPath @('ls-files','--others','--exclude-standard')).lines)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            $relative = ([string]$line).Replace('\','/')
            if (-not (Test-MorphospaceValidationReceiptPathAllowed $relative @($allowedRepository.allowed_paths))) { continue }
            $repositoryPrefix = $repositoryPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            if ($workspace.StartsWith($repositoryPrefix,$script:MorphospaceValidationReceiptPathComparison)) {
                $transactionPrefix = $workspace.Substring($repositoryPrefix.Length).Replace('\','/').TrimEnd('/') + '/receipts/transactions/'
                if ($relative.StartsWith($transactionPrefix,[StringComparison]::Ordinal)) { continue }
            }
            [void]$observedPaths.Add($relative)
        }
        $repositoryPrefix = $repositoryPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if ($output.StartsWith($repositoryPrefix,$script:MorphospaceValidationReceiptPathComparison)) {
            $outputRelative = $output.Substring($repositoryPrefix.Length).Replace('\','/')
            if (Test-MorphospaceValidationReceiptPathAllowed $outputRelative @($allowedRepository.allowed_paths)) { [void]$observedPaths.Add($outputRelative) }
        }
        foreach ($relative in @($observedPaths | Sort-Object)) { $changedPaths.Add([pscustomobject][ordered]@{ repo_id=$repoId; path=$relative }) | Out-Null }
    }

    $effectiveWorkMode=if($unit.PSObject.Properties.Name -contains 'work_mode'){[string]$unit.work_mode}else{'feature'}
    $snapshotEligible=$effectiveWorkMode -cin @('feature','validation-only') -and $sourceLockPresent -and ($unit.PSObject.Properties.Name -contains 'candidate_freeze') -and [string]$Evidence.result -cin @('fail','partial','blocked')
    if ($snapshotEligible) {
        $null=Assert-MorphospaceNonpassNativePath $(if([IO.Path]::IsPathRooted($OutPath)){$OutPath}else{Join-Path $workspace $OutPath})
        $null=Assert-MorphospaceNonpassNativePath $workspace
        $null=Assert-MorphospaceNonpassNativePath $output
        if (-not $outputDirectory.Equals((Join-Path $workspace 'receipts'),$script:MorphospaceValidationReceiptPathComparison)) { throw 'NONPASS custody output must be a direct receipts child.' }
        if ([string]$Evidence.receipt_id -cnotmatch '^[a-z0-9][a-z0-9-]{1,127}$') { throw 'NONPASS custody receipt ID is invalid.' }
        $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($inputArtifact in @($Evidence.artifacts)) {
            if (-not $ids.Add([string]$inputArtifact.artifact_id)) { throw 'NONPASS custody duplicate artifact IDs are forbidden.' }
            if ([string]$inputArtifact.artifact_id -ceq 'nonpass-evidence-custody' -or [string]$inputArtifact.kind -ceq 'nonpass-evidence-custody') { throw 'NONPASS custody reserved artifact ID or kind is caller supplied.' }
            if ([string]$inputArtifact.kind -ceq 'source-delivery-landing') { throw 'NONPASS custody source-delivery-landing typed closure is unsupported.' }
            $locator=[string]$inputArtifact.path
            $null=Assert-MorphospaceNonpassNativePath $(if([IO.Path]::IsPathRooted($locator)){$locator}else{Join-Path $outputDirectory $locator})
        }
    }
    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @($Evidence.artifacts)) {
        if ($null -ne $bootstrapAuthority -and [string]$artifact.artifact_id -cin @('bootstrap-source-lock','bootstrap-repository-map','bootstrap-begin-intent')) { throw 'Bootstrap validation reserved artifact ID is caller supplied.' }
        $properties = @($artifact.PSObject.Properties.Name | Sort-Object)
        if (('artifact_id|kind|path') -cne ($properties -join '|')) { throw 'Each validation artifact input must contain exactly artifact_id, kind, and path; SHA-256 is observed by the builder.' }
        $artifactPath = if ([IO.Path]::IsPathRooted([string]$artifact.path)) { [IO.Path]::GetFullPath([string]$artifact.path) } else { [IO.Path]::GetFullPath((Join-Path $outputDirectory ([string]$artifact.path))) }
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "Validation artifact does not exist: $([string]$artifact.path)" }
        $artifacts.Add([pscustomobject][ordered]@{ artifact_id=[string]$artifact.artifact_id; kind=[string]$artifact.kind; path=[string]$artifact.path; sha256=(Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() }) | Out-Null
    }
    if ($null -ne $bootstrapAuthority) {
        foreach ($artifact in @($bootstrapAuthority.artifacts)) { $artifacts.Add($artifact) | Out-Null }
    }

    if (-not $CreatedAt) { $CreatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $receipt = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.validation_receipt.v1'; receipt_id=[string]$Evidence.receipt_id; project_id=[string]$project.project_id; unit_id=$UnitId; created_at=$CreatedAt; tier=[string]$Evidence.tier; result=[string]$Evidence.result
        repository_revisions=@($repositoryRevisions.ToArray()); changed_paths=@($changedPaths.ToArray()); artifacts=@($artifacts.ToArray())
        criteria=@($Evidence.criteria | ForEach-Object { Copy-MorphospaceValidationReceiptValue $_ }); gates=@($Evidence.gates | ForEach-Object { Copy-MorphospaceValidationReceiptValue $_ })
        device_validation=Copy-MorphospaceValidationReceiptValue $Evidence.device_validation
    }
    [void](Assert-MorphospaceValidationReceiptStructure -Document $receipt -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1')
    $owned=[pscustomobject]@{handles=[Collections.Generic.List[IO.Stream]]::new();files=[Collections.Generic.List[string]]::new();directories=[Collections.Generic.List[string]]::new()}
    $published=$false
    try {
    if ($snapshotEligible) {
        New-MorphospaceNonpassEvidenceCustody -Workspace $workspace -Output $output -Receipt $receipt -Owned $owned
        [void](Assert-MorphospaceValidationReceiptStructure -Document $receipt -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1')
    }
    foreach ($path in $activeEnvelopeFiles.Keys) {
        if ((Get-MorphospaceValidationReceiptFileHash $path) -cne [string]$activeEnvelopeFiles[$path]) { throw 'Active-envelope validation receipt authority changed during generation.' }
    }
    if ($null -ne $bootstrapAuthority) { Assert-MorphospaceBootstrapValidationObservation -Authority $bootstrapAuthority }
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    Assert-MorphospaceValidationReceiptNoReparseAncestry $workspace $output
    if ($snapshotEligible) {
        $target=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $owned.files.Add($output)
        try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($receipt|ConvertTo-Json -Depth 100)+"`n");$target.Write($bytes);$target.Flush($true) } finally { $target.Dispose() }
        $published=$true
        return $receipt
    }
    $temporary = "$output.tmp-$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temporary,(($receipt | ConvertTo-Json -Depth 100) + "`n"),[Text.UTF8Encoding]::new($false))
    Assert-MorphospaceValidationReceiptNoReparseAncestry $workspace $output
    Move-Item -LiteralPath $temporary -Destination $output
    $published=$true
    return $receipt
    } finally {
        foreach ($handle in $owned.handles) { $handle.Dispose() }
        if (-not $published -and ($owned.files.Count -gt 0 -or $owned.directories.Count -gt 0)) {
            # A pathname ceases to prove ownership after handles close. Never
            # unlink it: another actor may already have replaced that file or
            # directory. Exact remnants can be reused; conflicting ones refuse.
            $sample=@($owned.files|Select-Object -First 8)-join', '
            try { Write-Warning "NONPASS receipt publication failed; preserving unpublished paths ($($owned.files.Count) created file names, $($owned.directories.Count) directories) because rollback ownership is uncertain. Sample: $sample" -WarningAction Continue } catch { }
        }
    }
}

Export-ModuleMember -Function Assert-MorphospaceValidationReceiptStructure, New-MorphospaceValidationReceiptV1, Assert-MorphospaceNonpassEvidenceSnapshotBinding
