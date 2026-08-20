param(
    [string]$Mode = "Build",
    [string]$ProfilePath = "",
    [string]$ProfileSha256 = "",
    [string]$SourceRoot = "",
    [string]$ReceiptPath = "",
    [string]$ToolPath = "",
    [string]$ToolSha256 = "",
    [string]$EnvironmentBindingsPath = "",
    [string]$EnvironmentBindingsSha256 = "",
    [string]$SignerObservationPath = "",
    [string]$SignerObservationSha256 = "",
    [int]$TimeoutSeconds = 900,
    [switch]$SelfTest,
    [switch]$TestInterruptBeforePublish,
    [int]$TestCancelAfterMilliseconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-StringSha256 {
    param([string]$Value)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Value)
    try { return ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function ConvertTo-CompactJson {
    param([object]$Value)
    return $Value | ConvertTo-Json -Depth 64 -Compress
}

function Assert-PropertySet {
    param([object]$Value, [string[]]$Required, [string[]]$Optional, [string]$Location)
    $actual = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object) } else { @($Value.PSObject.Properties.Name | Sort-Object) }
    $allowed = @($Required + $Optional | Sort-Object -Unique)
    $missing = @($Required | Where-Object { $_ -notin $actual })
    $unexpected = @($actual | Where-Object { $_ -notin $allowed })
    if ((@($missing)).Count -gt 0 -or (@($unexpected)).Count -gt 0) { throw "$Location has an invalid property set." }
}

function Get-OptionalProperty {
    param([object]$Value, [string]$Name)
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-ContainedPath {
    param([string]$Root, [string]$Relative, [string]$Location)
    if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathFullyQualified($Relative)) { throw "$Location must be a repository-relative path." }
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $relativeBack = [System.IO.Path]::GetRelativePath($Root, $resolved)
    if ([System.IO.Path]::IsPathRooted($relativeBack) -or $relativeBack -ceq ".." -or $relativeBack.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::Ordinal)) {
        throw "$Location escapes SourceRoot."
    }
    return $resolved
}

function Read-JsonFile {
    param([string]$Path, [string]$Location)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Location was not found." }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 64 }
    catch { throw "$Location is not valid JSON." }
}

function Read-BuildProfile {
    param([string]$Path, [string]$ExpectedSha256, [string]$Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Build profile was not found." }
    $actualSha256 = Get-Sha256 $fullPath
    if ($ExpectedSha256 -cnotmatch "^[a-f0-9]{64}$" -or $actualSha256 -cne $ExpectedSha256) { throw "Build profile SHA-256 does not match." }
    $document = Read-JsonFile $fullPath "Build profile"
    Assert-PropertySet $document @("schema", "profile_id", "working_directory", "executable", "arguments", "environment", "artifact") @("preflight") "Build profile"
    if ([string]$document.schema -cne "rusty.morphospace.quest_build_profile.v1" -or [string]$document.profile_id -cnotmatch "^[a-z0-9][a-z0-9._-]{0,95}$") { throw "Build profile identity is invalid." }
    $workingDirectory = Resolve-ContainedPath $Root ([string]$document.working_directory) "working_directory"
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) { throw "Build working directory does not exist." }
    $externalToolId = $null
    $profileExecutable = $null
    if ([string]$document.executable -ceq "gradle") { $externalToolId = "gradle" }
    else {
        $profileExecutable = Resolve-ContainedPath $Root ([string]$document.executable) "executable"
        if (-not (Test-Path -LiteralPath $profileExecutable -PathType Leaf)) { throw "Build executable does not exist." }
    }
    if ((@($document.arguments)).Count -gt 128 -or (@($document.arguments | Where-Object { $_ -isnot [string] -or $_.Length -gt 1024 })).Count -gt 0) { throw "Build profile arguments are invalid." }
    Assert-PropertySet $document.artifact @("relative_path", "kind") @() "Build profile artifact"
    if ([string]$document.artifact.kind -cne "single-base-apk") { throw "Build profile artifact kind is invalid." }
    $artifact = Resolve-ContainedPath $Root ([string]$document.artifact.relative_path) "artifact.relative_path"
    if ([System.IO.Path]::GetExtension($artifact) -cne ".apk") { throw "Build profile artifact must be one APK." }
    if ($null -eq $document.environment -or (@($document.environment.PSObject.Properties)).Count -gt 32 -or (@($document.environment.PSObject.Properties | Where-Object { $_.Name -cnotmatch "^[A-Z][A-Z0-9_]{0,63}$" -or [string]$_.Value -cnotmatch "^[a-z0-9][a-z0-9._-]{0,95}$" })).Count -gt 0) { throw "Build profile environment bindings are invalid." }
    $preflight = Get-OptionalProperty $document "preflight"
    if ($null -ne $preflight) { Assert-PropertySet $preflight @() @("manifest_relative_dependencies", "lockfiles", "toolchain", "identity", "environment_projection", "output") "Build profile preflight" }
    return [pscustomobject]@{ Document = $document; Path = $fullPath; Sha256 = $actualSha256; Root = $Root; WorkingDirectory = $workingDirectory; ProfileExecutable = $profileExecutable; ExternalToolId = $externalToolId; Artifact = $artifact; Preflight = $preflight }
}

function Resolve-EnvironmentBindings {
    param([object]$Profile, [string]$BindingsPath, [string]$BindingsSha256)
    $requirements = @($Profile.environment.PSObject.Properties)
    if ((@($requirements)).Count -eq 0) {
        if ($BindingsPath -or $BindingsSha256) { throw "Environment binding inputs were supplied for a profile that declares none." }
        return [pscustomobject]@{ Values = @{}; Evidence = @() }
    }
    if (-not $BindingsPath -or -not (Test-Path -LiteralPath $BindingsPath -PathType Leaf)) { throw "This build profile requires one private environment-binding file." }
    $actualSha256 = Get-Sha256 $BindingsPath
    if ($BindingsSha256 -cnotmatch "^[a-f0-9]{64}$" -or $actualSha256 -cne $BindingsSha256) { throw "Environment-binding file SHA-256 does not match." }
    $document = Read-JsonFile ([System.IO.Path]::GetFullPath($BindingsPath)) "Environment binding document"
    Assert-PropertySet $document @("schema", "bindings") @() "Environment binding document"
    if ([string]$document.schema -cne "rusty.morphospace.local_quest_build_environment.v1") { throw "Environment-binding schema is invalid." }
    $byId = @{}
    foreach ($binding in @($document.bindings)) {
        Assert-PropertySet $binding @("id", "path", "kind", "git_revision", "git_tree") @() "Environment binding"
        $bindingId = [string]$binding.id
        if ($bindingId -cnotmatch "^[a-z0-9][a-z0-9._-]{0,95}$" -or $byId.ContainsKey($bindingId)) { throw "Environment binding id is invalid or duplicated." }
        if ([string]$binding.kind -cnotin @("file", "directory") -or -not [System.IO.Path]::IsPathFullyQualified([string]$binding.path)) { throw "Environment binding path or kind is invalid." }
        $bindingPath = [System.IO.Path]::GetFullPath([string]$binding.path)
        $pathType = if ([string]$binding.kind -ceq "file") { "Leaf" } else { "Container" }
        if (-not (Test-Path -LiteralPath $bindingPath -PathType $pathType)) { throw "Environment binding target does not exist." }
        $revision = [string]$binding.git_revision
        $tree = [string]$binding.git_tree
        if (($revision -or $tree) -and ($revision -cnotmatch "^[a-f0-9]{40}$" -or $tree -cnotmatch "^[a-f0-9]{40}$" -or [string]$binding.kind -cne "directory")) { throw "Git-bound environment entries require one exact revision/tree pair and directory kind." }
        if ($revision) {
            $observedRevision = ((& git -C $bindingPath rev-parse HEAD 2>$null) -join "").Trim()
            $observedTree = ((& git -C $bindingPath rev-parse "HEAD^{tree}" 2>$null) -join "").Trim()
            $observedStatus = (& git -C $bindingPath status --porcelain=v1 -z 2>$null) -join ""
            if ($LASTEXITCODE -ne 0 -or $observedRevision -cne $revision -or $observedTree -cne $tree -or $observedStatus) { throw "Git-bound environment entry is not the exact clean revision and tree." }
        }
        $byId[$bindingId] = [pscustomobject]@{ Path = $bindingPath; Kind = [string]$binding.kind; Revision = $revision; Tree = $tree }
    }
    $values = @{}
    $evidence = @()
    foreach ($requirement in $requirements) {
        $bindingId = [string]$requirement.Value
        if (-not $byId.ContainsKey($bindingId)) { throw "Required environment binding '$bindingId' is missing." }
        $binding = $byId[$bindingId]
        $values[[string]$requirement.Name] = $binding.Path
        $evidence += [ordered]@{ variable = [string]$requirement.Name; binding_id = $bindingId; kind = $binding.Kind; value_sha256 = Get-StringSha256 $binding.Path; git_revision = if ($binding.Revision) { $binding.Revision } else { $null }; git_tree = if ($binding.Tree) { $binding.Tree } else { $null } }
    }
    return [pscustomobject]@{ Values = $values; Evidence = @($evidence | Sort-Object variable) }
}

function Resolve-Execution {
    param([object]$Profile, [string]$ResolvedToolPath, [string]$ExpectedToolSha256)
    if ($Profile.ExternalToolId) {
        if ([string]::IsNullOrWhiteSpace($ResolvedToolPath) -or -not [System.IO.Path]::IsPathFullyQualified($ResolvedToolPath) -or -not (Test-Path -LiteralPath $ResolvedToolPath -PathType Leaf)) { throw "The gradle profile requires one absolute private ToolPath." }
        $boundToolPath = [System.IO.Path]::GetFullPath($ResolvedToolPath)
        if ([System.IO.Path]::GetFileName($boundToolPath) -cnotin @("gradle.bat", "gradle.exe")) { throw "The gradle profile requires gradle.bat or gradle.exe." }
        $toolSha256 = Get-Sha256 $boundToolPath
        if ($ExpectedToolSha256 -cnotmatch "^[a-f0-9]{64}$" -or $toolSha256 -cne $ExpectedToolSha256) { throw "The resolved Gradle executable does not match ToolSha256." }
        $extension = [System.IO.Path]::GetExtension($boundToolPath).ToLowerInvariant()
    } else {
        $boundToolPath = [string]$Profile.ProfileExecutable
        $toolSha256 = Get-Sha256 $boundToolPath
        $extension = [System.IO.Path]::GetExtension($boundToolPath).ToLowerInvariant()
    }
    $cliArguments = @($Profile.Document.arguments | ForEach-Object { [string]$_ })
    if ($extension -ceq ".ps1") {
        $fileName = [System.IO.Path]::GetFullPath((Get-Command pwsh -ErrorAction Stop).Source)
        $arguments = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $boundToolPath) + $cliArguments
    } elseif ($extension -cin @(".exe", ".cmd", ".bat")) {
        $fileName = $boundToolPath
        $arguments = $cliArguments
    } else { throw "Build executable type is not allowlisted." }
    return [pscustomobject]@{ FileName = $fileName; Arguments = @($arguments); BoundToolPath = $boundToolPath; BoundToolSha256 = $toolSha256; ProfileArguments = $cliArguments; WorkingDirectory = $Profile.WorkingDirectory }
}

function Get-SourceObservation {
    param([string]$Root)
    $inside = ((& git -C $Root rev-parse --is-inside-work-tree 2>$null) -join "").Trim()
    if ($LASTEXITCODE -ne 0 -or $inside -cne "true") { return [ordered]@{ git_available = $false; revision = $null; tree = $null; dirty = $null } }
    $revision = ((& git -C $Root rev-parse HEAD 2>$null) -join "").Trim()
    $tree = ((& git -C $Root rev-parse "HEAD^{tree}" 2>$null) -join "").Trim()
    $status = (& git -C $Root status --porcelain=v1 -z 2>$null) -join ""
    return [ordered]@{ git_available = $true; revision = $revision; tree = $tree; dirty = -not [string]::IsNullOrEmpty($status) }
}

function Add-PreflightCheck {
    param([System.Collections.Generic.List[object]]$Checks, [string]$CapabilityId, [string]$Status, [string]$ReasonCode, [string]$Detail)
    $normalizedCapabilityId = (($CapabilityId.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-"))
    if ($normalizedCapabilityId -notmatch "^[a-z0-9][a-z0-9-]{1,127}$") { throw "Preflight capability identifier is invalid." }
    $Checks.Add([pscustomobject][ordered]@{ capability_id = $normalizedCapabilityId; status = $Status; reason_code = $ReasonCode; detail = $Detail })
}

function Get-ChildEnvironmentProjection {
    param([object]$Preflight, [hashtable]$BindingValues, [System.Collections.Generic.List[object]]$Checks)
    $projection = if ($null -eq $Preflight) { $null } else { Get-OptionalProperty $Preflight "environment_projection" }
    if ($null -ne $projection) { Assert-PropertySet $projection @() @("passthrough", "prohibited_parent_variables") "Environment projection" }
    $defaultPassthrough = @("COMSPEC", "HOME", "PATH", "PATHEXT", "SYSTEMROOT", "TEMP", "TMP", "TMPDIR", "WINDIR")
    $passthrough = if ($null -ne $projection -and $null -ne (Get-OptionalProperty $projection "passthrough")) { @($projection.passthrough) } else { $defaultPassthrough }
    $prohibited = if ($null -ne $projection -and $null -ne (Get-OptionalProperty $projection "prohibited_parent_variables")) { @($projection.prohibited_parent_variables) } else { @() }
    if ((@($passthrough | Select-Object -Unique)).Count -ne (@($passthrough)).Count -or (@($prohibited | Select-Object -Unique)).Count -ne (@($prohibited)).Count -or (@($passthrough + $prohibited | Where-Object { $_ -isnot [string] -or $_ -cnotmatch "^[A-Z][A-Z0-9_]{0,63}$" })).Count -gt 0) { throw "Environment projection is invalid." }
    $child = @{}
    $evidence = @()
    foreach ($name in @($passthrough | Sort-Object)) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $child[$name] = $value }
        $evidence += [ordered]@{ variable = $name; source = "host-passthrough"; present = $null -ne $value; value_sha256 = if ($null -ne $value) { Get-StringSha256 $value } else { $null } }
    }
    foreach ($name in @($prohibited | Sort-Object)) {
        $present = $null -ne [Environment]::GetEnvironmentVariable($name)
        $checkStatus = if ($present) { "contradiction" } else { "passed" }
        $reasonCode = if ($present) { "prohibited-parent-environment" } else { "" }
        $detail = "Parent variable $name is $(if ($present) { 'prohibited' } else { 'not present' })."
        Add-PreflightCheck $Checks "environment.prohibited.$($name.ToLowerInvariant())" $checkStatus $reasonCode $detail
    }
    foreach ($name in @($BindingValues.Keys | Sort-Object)) {
        $child[$name] = [string]$BindingValues[$name]
        $evidence += [ordered]@{ variable = $name; source = "profile-binding"; present = $true; value_sha256 = Get-StringSha256 ([string]$BindingValues[$name]) }
    }
    return [pscustomobject]@{ Values = $child; Evidence = @($evidence | Sort-Object variable, source) }
}

function Read-SignerObservation {
    param([object]$Preflight, [string]$Path, [string]$ExpectedSha256, [System.Collections.Generic.List[object]]$Checks)
    $identity = if ($null -eq $Preflight) { $null } else { Get-OptionalProperty $Preflight "identity" }
    if ($null -ne $identity) { Assert-PropertySet $identity @() @("package_id", "application_id", "expected_current_signer_sha256") "Build profile identity" }
    $packageId = if ($null -ne $identity) { [string](Get-OptionalProperty $identity "package_id") } else { "" }
    $applicationId = if ($null -ne $identity) { [string](Get-OptionalProperty $identity "application_id") } else { "" }
    if ($null -ne $identity -and ((Get-OptionalProperty $identity "package_id") -ne $null) -and $packageId.Length -eq 0) {
        Add-PreflightCheck $Checks "identity.package" "contradiction" "package-id-missing" "The profile declares an empty package identity."
    }
    if ($null -ne $identity -and ((Get-OptionalProperty $identity "application_id") -ne $null) -and $applicationId.Length -eq 0) {
        Add-PreflightCheck $Checks "identity.application" "contradiction" "application-id-missing" "The profile declares an empty application identity."
    }
    $expected = if ($null -ne $identity -and $null -ne (Get-OptionalProperty $identity "expected_current_signer_sha256")) { @($identity.expected_current_signer_sha256 | ForEach-Object { [string]$_ } | Sort-Object) } else { @() }
    if ((@($expected | Where-Object { $_ -cnotmatch "^[a-f0-9]{64}$" })).Count -gt 0 -or (@($expected | Select-Object -Unique)).Count -ne @($expected).Count) { throw "Expected signer identity is invalid." }
    $result = [ordered]@{ package_id = if ($packageId) { $packageId } else { $null }; application_id = if ($applicationId) { $applicationId } else { $null }; expected_current_signer_sha256 = $expected; observed_current_signer_sha256 = @(); observation_sha256 = $null }
    if ((@($expected)).Count -eq 0) { return $result }
    if (-not $Path) {
        Add-PreflightCheck $Checks "identity.signer" "incomplete" "signer-observation-unavailable" "Signer expectation is declared but no owner observation was supplied."
        return $result
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Signer observation was not found." }
    $actualSha256 = Get-Sha256 $Path
    if ($ExpectedSha256 -cnotmatch "^[a-f0-9]{64}$" -or $actualSha256 -cne $ExpectedSha256) { throw "Signer observation SHA-256 does not match." }
    $document = Read-JsonFile ([System.IO.Path]::GetFullPath($Path)) "Signer observation"
    Assert-PropertySet $document @("schema", "application_id", "current_signer_sha256") @() "Signer observation"
    if ([string]$document.schema -cne "rusty.morphospace.quest_signer_observation.v1" -or [string]$document.application_id -notmatch ".") { throw "Signer observation identity is invalid." }
    $observed = @($document.current_signer_sha256 | ForEach-Object { [string]$_ } | Sort-Object)
    if (@($observed).Count -eq 0 -or (@($observed | Where-Object { $_ -cnotmatch "^[a-f0-9]{64}$" })).Count -gt 0 -or (@($observed | Select-Object -Unique)).Count -ne @($observed).Count) { throw "Signer observation certificates are invalid." }
    $result.observed_current_signer_sha256 = $observed
    $result.observation_sha256 = $actualSha256
    if ($applicationId -and [string]$document.application_id -cne $applicationId) { Add-PreflightCheck $Checks "identity.application" "contradiction" "application-id-mismatch" "Signer observation application identity does not match the profile." }
    if (($expected -join "|") -cne ($observed -join "|")) { Add-PreflightCheck $Checks "identity.signer" "contradiction" "signer-mismatch" "Observed current signer set does not match the profile expectation." }
    else { Add-PreflightCheck $Checks "identity.signer" "passed" "" "Observed current signer set matches the profile expectation." }
    return $result
}

function Get-DeclaredRustToolchainChannel {
    param([string]$Path)
    $fileName = [System.IO.Path]::GetFileName($Path)
    if ($fileName -cnotin @("rust-toolchain", "rust-toolchain.toml")) { return $null }
    $text = Get-Content -Raw -LiteralPath $Path
    if ($fileName -ceq "rust-toolchain") {
        $channel = $text.Trim()
        if ($channel -match "^[A-Za-z0-9._+-]{1,128}$") { return $channel }
        return $null
    }
    $match = [regex]::Match($text, '(?m)^\s*channel\s*=\s*"([A-Za-z0-9._+-]{1,128})"\s*$')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Invoke-QuestBuildPreflight {
    param([object]$Profile, [object]$Execution, [object]$Environment, [string]$SignerPath, [string]$SignerSha256)
    $checks = [System.Collections.Generic.List[object]]::new()
    $source = Get-SourceObservation $Profile.Root
    $sourceStatus = if ($source.git_available) { "passed" } else { "incomplete" }
    $sourceReason = if ($source.git_available) { "" } else { "source-git-unavailable" }
    $sourceDetail = "Source Git revision and tree are $(if ($source.git_available) { 'available' } else { 'unavailable' })."
    Add-PreflightCheck $checks "source.git" $sourceStatus $sourceReason $sourceDetail
    $dependencies = @()
    $lockfiles = @()
    $toolchain = @()
    $preflight = $Profile.Preflight
    if ($null -ne $preflight) {
        $dependencyPaths = Get-OptionalProperty $preflight "manifest_relative_dependencies"
        if ($null -ne $dependencyPaths) {
            if ((@($dependencyPaths | Select-Object -Unique)).Count -ne (@($dependencyPaths)).Count) { throw "Manifest-relative dependencies are duplicated." }
            foreach ($relativePath in @($dependencyPaths | Sort-Object)) {
                $resolved = Resolve-ContainedPath $Profile.Root ([string]$relativePath) "manifest_relative_dependencies"
                if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                    Add-PreflightCheck $checks "dependency.$([IO.Path]::GetFileName($relativePath).ToLowerInvariant())" "contradiction" "manifest-relative-dependency-missing" "Declared manifest-relative dependency is missing."
                    $dependencies += [ordered]@{ relative_path = [string]$relativePath; sha256 = $null; present = $false }
                } else {
                    $dependencies += [ordered]@{ relative_path = [string]$relativePath; sha256 = Get-Sha256 $resolved; present = $true }
                    Add-PreflightCheck $checks "dependency.$([IO.Path]::GetFileName($relativePath).ToLowerInvariant())" "passed" "" "Declared manifest-relative dependency is present."
                }
            }
        }
        $lockfilePaths = Get-OptionalProperty $preflight "lockfiles"
        if ($null -ne $lockfilePaths) {
            if ((@($lockfilePaths | Select-Object -Unique)).Count -ne (@($lockfilePaths)).Count) { throw "Declared lockfiles are duplicated." }
            foreach ($relativePath in @($lockfilePaths | Sort-Object)) {
                $resolved = Resolve-ContainedPath $Profile.Root ([string]$relativePath) "lockfiles"
                if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                    Add-PreflightCheck $checks "lockfile.$([IO.Path]::GetFileName($relativePath).ToLowerInvariant())" "contradiction" "lockfile-missing" "Declared lockfile is missing."
                    $lockfiles += [ordered]@{ relative_path = [string]$relativePath; sha256 = $null; present = $false }
                } else {
                    $lockfiles += [ordered]@{ relative_path = [string]$relativePath; sha256 = Get-Sha256 $resolved; present = $true }
                    Add-PreflightCheck $checks "lockfile.$([IO.Path]::GetFileName($relativePath).ToLowerInvariant())" "passed" "" "Declared lockfile is present."
                }
            }
        }
        $toolchainConfig = Get-OptionalProperty $preflight "toolchain"
        if ($null -ne $toolchainConfig) {
            Assert-PropertySet $toolchainConfig @() @("repository_files", "required_targets") "Toolchain preflight"
            foreach ($relativePath in @((Get-OptionalProperty $toolchainConfig "repository_files") | Sort-Object)) {
                $resolved = Resolve-ContainedPath $Profile.Root ([string]$relativePath) "toolchain.repository_files"
                if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                    Add-PreflightCheck $checks "toolchain.file.$([IO.Path]::GetFileName($relativePath).ToLowerInvariant())" "contradiction" "toolchain-file-missing" "Declared repository-owned toolchain file is missing."
                    $toolchain += [ordered]@{ kind = "repository-file"; relative_path = [string]$relativePath; sha256 = $null; present = $false; declared_rust_channel = $null }
                } else {
                    $declaredChannel = Get-DeclaredRustToolchainChannel $resolved
                    $toolchain += [ordered]@{ kind = "repository-file"; relative_path = [string]$relativePath; sha256 = Get-Sha256 $resolved; present = $true; declared_rust_channel = $declaredChannel }
                    Add-PreflightCheck $checks "toolchain.file.$([IO.Path]::GetFileName($relativePath).ToLowerInvariant())" "passed" "" "Declared repository-owned toolchain file is present."
                }
            }
            $requiredTargets = @((Get-OptionalProperty $toolchainConfig "required_targets") | Sort-Object)
            if ((@($requiredTargets)).Count -gt 0) {
                $rustup = Get-Command rustup -ErrorAction SilentlyContinue
                if ($null -eq $rustup) {
                    foreach ($target in $requiredTargets) {
                        Add-PreflightCheck $checks "toolchain.target.$target" "contradiction" "rustup-unavailable" "rustup is required to observe the declared target."
                        $toolchain += [ordered]@{ kind = "required-target"; target = [string]$target; installed = $false; observer = "rustup-unavailable" }
                    }
                } else {
                    $installedTargets = @((& $rustup.Source target list --installed 2>$null) | ForEach-Object { [string]$_ })
                    foreach ($target in $requiredTargets) {
                        $targetPresent = $target -in $installedTargets
                        $targetStatus = if ($targetPresent) { "passed" } else { "contradiction" }
                        $targetReason = if ($targetPresent) { "" } else { "required-target-missing" }
                        $targetDetail = "Declared Rust target $target is $(if ($targetPresent) { 'installed' } else { 'missing' })."
                        Add-PreflightCheck $checks "toolchain.target.$target" $targetStatus $targetReason $targetDetail
                        $toolchain += [ordered]@{ kind = "required-target"; target = [string]$target; installed = $targetPresent; observer = "rustup" }
                    }
                }
            }
        }
    }
    $projectedEnvironment = Get-ChildEnvironmentProjection $preflight $Environment.Values $checks
    $identity = Read-SignerObservation $preflight $SignerPath $SignerSha256 $checks
    $outputConfig = if ($null -eq $preflight) { $null } else { Get-OptionalProperty $preflight "output" }
    if ($null -ne $outputConfig) { Assert-PropertySet $outputConfig @() @("lane", "collision_policy", "allow_source_root") "Output preflight" }
    $lane = if ($null -ne $outputConfig -and $null -ne (Get-OptionalProperty $outputConfig "lane")) { [string]$outputConfig.lane } else { "warm" }
    $collisionPolicy = if ($null -ne $outputConfig -and $null -ne (Get-OptionalProperty $outputConfig "collision_policy")) { [string]$outputConfig.collision_policy } else { "new-only" }
    $allowSourceRoot = if ($null -ne $outputConfig -and $null -ne (Get-OptionalProperty $outputConfig "allow_source_root")) { [bool]$outputConfig.allow_source_root } else { $true }
    if ($lane -cnotin @("warm", "candidate") -or $collisionPolicy -cnotin @("new-only", "content-addressed")) { throw "Output preflight is invalid." }
    if ($lane -ceq "candidate") {
        if (-not $source.git_available) {
            Add-PreflightCheck $checks "output.candidate-source" "incomplete" "candidate-source-git-unavailable" "Candidate output requires an observable source revision and tree."
        } elseif ($source.dirty) {
            Add-PreflightCheck $checks "output.candidate-source" "contradiction" "candidate-source-not-clean" "Candidate output requires a clean source tree."
        } else {
            Add-PreflightCheck $checks "output.candidate-source" "passed" "" "Candidate source tree is clean."
        }
        Add-PreflightCheck $checks "output.candidate-collision-policy" $(if ($collisionPolicy -eq "content-addressed") { "passed" } else { "contradiction" }) $(if ($collisionPolicy -eq "content-addressed") { "" } else { "candidate-output-not-content-addressed" }) "Candidate output collision policy is $(if ($collisionPolicy -eq "content-addressed") { 'content-addressed' } else { 'not content-addressed' })."
    }
    $insideSource = -not [System.IO.Path]::IsPathRooted([System.IO.Path]::GetRelativePath($Profile.Root, $Profile.Artifact))
    $sourceRootPolicyPasses = $allowSourceRoot -or -not $insideSource
    Add-PreflightCheck $checks "output.source-root" $(if ($sourceRootPolicyPasses) { "passed" } else { "contradiction" }) $(if ($sourceRootPolicyPasses) { "" } else { "output-inside-source-root" }) "Output source-root policy is satisfied."
    $outputExists = Test-Path -LiteralPath $Profile.Artifact
    Add-PreflightCheck $checks "output.collision" $(if ($outputExists) { "contradiction" } else { "passed" }) $(if ($outputExists) { "output-collision" } else { "" }) "Declared output is $(if ($outputExists) { 'already present' } else { 'available' })."
    $binding = [ordered]@{ profile_sha256 = $Profile.Sha256; profile_id = [string]$Profile.Document.profile_id; executable = [ordered]@{ profile_path = $Execution.BoundToolPath; profile_sha256 = $Execution.BoundToolSha256; child_path = $Execution.FileName; child_sha256 = Get-Sha256 $Execution.FileName; arguments = @($Execution.Arguments) }; source = $source; manifest_relative_dependencies = @($dependencies); lockfiles = @($lockfiles); toolchain = @($toolchain); environment = @($projectedEnvironment.Evidence); identity = $identity; output = [ordered]@{ lane = $lane; collision_policy = $collisionPolicy; allow_source_root = $allowSourceRoot; path = $Profile.Artifact } }
    $bindingSha256 = Get-StringSha256 (ConvertTo-CompactJson $binding)
    $status = if ((@($checks | Where-Object { $_.status -eq "contradiction" })).Count -gt 0) { "contradiction" } elseif ((@($checks | Where-Object { $_.status -eq "incomplete" })).Count -gt 0) { "incomplete" } else { "passed" }
    $reasonCodes = @($checks | Where-Object { $_.reason_code } | ForEach-Object { [string]$_.reason_code } | Sort-Object -Unique)
    $values = @(
        [ordered]@{ key = "quest-build.profile-id"; value = [string]$Profile.Document.profile_id },
        [ordered]@{ key = "quest-build.profile-sha256"; value = $Profile.Sha256 },
        [ordered]@{ key = "quest-build.invocation-binding-sha256"; value = $bindingSha256 },
        [ordered]@{ key = "quest-build.executable-sha256"; value = $Execution.BoundToolSha256 },
        [ordered]@{ key = "quest-build.arguments-sha256"; value = Get-StringSha256 ((@($Execution.Arguments) -join "`u{001F}")) },
        [ordered]@{ key = "quest-build.output-lane"; value = $lane },
        [ordered]@{ key = "quest-build.output-collision-policy"; value = $collisionPolicy }
    )
    if ($source.revision) { $values += [ordered]@{ key = "quest-build.source-revision"; value = [string]$source.revision } }
    if ($source.tree) { $values += [ordered]@{ key = "quest-build.source-tree"; value = [string]$source.tree } }
    if ($identity.package_id) { $values += [ordered]@{ key = "quest-build.package-id"; value = [string]$identity.package_id } }
    if ($identity.application_id) { $values += [ordered]@{ key = "quest-build.application-id"; value = [string]$identity.application_id } }
    foreach ($entry in @($toolchain | Where-Object { $_.kind -eq "repository-file" -and $_.declared_rust_channel })) {
        $values += [ordered]@{ key = "quest-build.declared-rust-channel.$([System.IO.Path]::GetFileName([string]$entry.relative_path).ToLowerInvariant())"; value = [string]$entry.declared_rust_channel }
    }
    $observation = [ordered]@{ schema = "rusty.morphospace.workflow.execution_preflight_observation.v1"; observation_id = "quest-build-preflight-$bindingSha256"; created_at = [DateTime]::UtcNow.ToString("o"); subject = "quest-build-profile"; values = @($values | Sort-Object key); capabilities = @($checks | Sort-Object capability_id | ForEach-Object { [ordered]@{ capability_id = $_.capability_id; available = $_.status -eq "passed"; detail = if ($_.reason_code) { $_.reason_code } else { $_.detail } } }) }
    $payload = [ordered]@{ artifact = $null; source = $source; lockfiles = @($lockfiles); toolchain = @($toolchain); environment = @($projectedEnvironment.Evidence); identity = $identity; output = $binding.output; execution_preflight_observation = $observation }
    return [pscustomobject]@{ Status = $status; ReasonCodes = $reasonCodes; Binding = $binding; BindingSha256 = $bindingSha256; Observation = $observation; ObservationSha256 = Get-StringSha256 (ConvertTo-CompactJson $observation); ChildEnvironment = $projectedEnvironment.Values; Payload = $payload }
}

function Invoke-ChildProcess {
    param([object]$Execution, [hashtable]$EnvironmentValues, [string]$BaseReceiptPath, [int]$DeadlineSeconds, [int]$CancelAfterMilliseconds)
    if ($DeadlineSeconds -lt 1 -or $DeadlineSeconds -gt 3600) { throw "TimeoutSeconds must be between 1 and 3600." }
    $stdoutFinal = "$BaseReceiptPath.stdout.bin"
    $stderrFinal = "$BaseReceiptPath.stderr.bin"
    if ((Test-Path -LiteralPath $stdoutFinal) -or (Test-Path -LiteralPath $stderrFinal)) { throw "Raw stream evidence path already exists." }
    $stdoutTemp = "$stdoutFinal.$([guid]::NewGuid().ToString('N')).tmp"
    $stderrTemp = "$stderrFinal.$([guid]::NewGuid().ToString('N')).tmp"
    $process = [System.Diagnostics.Process]::new()
    $started = $false
    $stdoutStream = $null
    $stderrStream = $null
    $script:cancelRequested = $false
    $cancelHandler = [ConsoleCancelEventHandler]{ param($sender, $eventArgs) $eventArgs.Cancel = $true; $script:cancelRequested = $true }
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [string]$Execution.FileName
        $startInfo.WorkingDirectory = [string]$Execution.WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment.Clear()
        foreach ($name in @($EnvironmentValues.Keys | Sort-Object)) { [void]($startInfo.Environment[$name] = [string]$EnvironmentValues[$name]) }
        foreach ($argument in @($Execution.Arguments)) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "Build process did not start." }
        $started = $true
        [Console]::add_CancelKeyPress($cancelHandler)
        $stdoutStream = [System.IO.File]::Open($stdoutTemp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stderrStream = [System.IO.File]::Open($stderrTemp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
            $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $status = "passed"
            while (-not $process.WaitForExit(50)) {
                if ($script:cancelRequested -or ($CancelAfterMilliseconds -gt 0 -and $timer.ElapsedMilliseconds -ge $CancelAfterMilliseconds)) { $status = "cancelled"; break }
                if ($timer.Elapsed.TotalSeconds -ge $DeadlineSeconds) { $status = "timed_out"; break }
            }
            if ($status -ne "passed") {
                try { $process.Kill($true) } catch { }
                if (-not $process.WaitForExit(10000)) { throw "Build process tree did not terminate after $status." }
            } else {
                [void]$process.WaitForExit()
            }
            [void]$stdoutTask.GetAwaiter().GetResult()
            [void]$stderrTask.GetAwaiter().GetResult()
            $stdoutStream.Flush($true)
            $stderrStream.Flush($true)
            if ($status -eq "passed" -and $process.ExitCode -ne 0) { $status = "failed" }
        } finally {
            if ($null -ne $stdoutStream) { $stdoutStream.Dispose() }
            if ($null -ne $stderrStream) { $stderrStream.Dispose() }
        }
        [System.IO.File]::Move($stdoutTemp, $stdoutFinal)
        [System.IO.File]::Move($stderrTemp, $stderrFinal)
        return [pscustomobject]@{ Status = $status; ExitCode = [int]$process.ExitCode; Streams = [ordered]@{ captured = $true; stdout = [ordered]@{ path = $stdoutFinal; sha256 = Get-Sha256 $stdoutFinal; size_bytes = (Get-Item -LiteralPath $stdoutFinal).Length }; stderr = [ordered]@{ path = $stderrFinal; sha256 = Get-Sha256 $stderrFinal; size_bytes = (Get-Item -LiteralPath $stderrFinal).Length } } }
    } finally {
        try { [Console]::remove_CancelKeyPress($cancelHandler) } catch { }
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit(10000)
        }
        $process.Dispose()
        foreach ($temporaryPath in @($stdoutTemp, $stderrTemp)) { if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force } }
    }
}

function Assert-TerminalResult {
    param([object]$Result)
    Assert-PropertySet $Result @("schema", "operation", "terminal_status", "profile", "invocation", "observation", "reason_codes", "streams", "owner_payload") @() "Terminal result"
    if ([string]$Result.schema -cne "rusty.morphospace.quest_build_terminal_result.v1" -or [string]$Result.operation -cnotin @("preflight", "build")) { throw "Terminal result identity is invalid." }
    $preflightStatuses = @("passed", "contradiction", "incomplete")
    $buildStatuses = @($preflightStatuses + @("failed", "timed_out", "cancelled"))
    if ([string]$Result.terminal_status -cnotin $buildStatuses -or ([string]$Result.operation -ceq "preflight" -and [string]$Result.terminal_status -cnotin $preflightStatuses)) { throw "Terminal result status is invalid." }
    Assert-PropertySet $Result.profile @("profile_id", "profile_sha256") @() "Terminal result profile"
    Assert-PropertySet $Result.invocation @("binding_sha256", "executable", "arguments") @() "Terminal result invocation"
    Assert-PropertySet $Result.observation @("observation_id", "sha256") @() "Terminal result observation"
    Assert-PropertySet $Result.streams @("captured", "stdout", "stderr") @() "Terminal result streams"
    Assert-PropertySet $Result.owner_payload @("artifact", "source", "lockfiles", "toolchain", "environment", "identity", "output", "execution_preflight_observation") @() "Terminal result owner payload"
    if ($null -ne $Result.owner_payload.execution_preflight_observation) {
        $embeddedObservation = $Result.owner_payload.execution_preflight_observation
        Assert-PropertySet $embeddedObservation @("schema", "observation_id", "created_at", "subject", "values", "capabilities") @() "Embedded execution preflight observation"
        if ([string]$embeddedObservation.schema -cne "rusty.morphospace.workflow.execution_preflight_observation.v1" -or [string]$embeddedObservation.observation_id -cne [string]$Result.observation.observation_id -or (Get-StringSha256 (ConvertTo-CompactJson $embeddedObservation)) -cne [string]$Result.observation.sha256) { throw "Terminal result does not bind its embedded execution preflight observation." }
    }
}

function New-TerminalResult {
    param([string]$Operation, [string]$Status, [object]$Profile, [object]$Execution, [object]$Preflight, [string[]]$ReasonCodes, [object]$Streams, [object]$Payload)
    $result = [ordered]@{
        schema = "rusty.morphospace.quest_build_terminal_result.v1"
        operation = $Operation
        terminal_status = $Status
        profile = [ordered]@{ profile_id = if ($null -ne $Profile) { [string]$Profile.Document.profile_id } else { $null }; profile_sha256 = if ($null -ne $Profile) { [string]$Profile.Sha256 } else { $null } }
        invocation = [ordered]@{ binding_sha256 = if ($null -ne $Preflight) { [string]$Preflight.BindingSha256 } else { Get-StringSha256 "quest-build-terminal-result-empty-binding-v1" }; executable = if ($null -ne $Execution) { [string]$Execution.FileName } else { $null }; arguments = if ($null -ne $Execution) { @($Execution.Arguments) } else { @() } }
        observation = [ordered]@{ observation_id = if ($null -ne $Preflight) { [string]$Preflight.Observation.observation_id } else { $null }; sha256 = if ($null -ne $Preflight) { [string]$Preflight.ObservationSha256 } else { $null } }
        reason_codes = @($ReasonCodes | Where-Object { $_ } | Sort-Object -Unique)
        streams = if ($null -ne $Streams) { $Streams } else { [ordered]@{ captured = $false; stdout = $null; stderr = $null } }
        owner_payload = if ($null -ne $Payload) { $Payload } else { [ordered]@{ artifact = $null; source = $null; lockfiles = @(); toolchain = @(); environment = @(); identity = [ordered]@{}; output = [ordered]@{}; execution_preflight_observation = $null } }
    }
    Assert-TerminalResult $result
    return $result
}

function Publish-TerminalResult {
    param([object]$Result, [string]$Path, [bool]$InterruptBeforePublish)
    $json = ConvertTo-CompactJson $Result
    if (-not $Path) { return [pscustomobject]@{ Json = $json; published = $false; interrupted = $false } }
    $finalPath = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $finalPath) { throw "ReceiptPath already exists." }
    $parent = Split-Path -Parent $finalPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporaryPath = "$finalPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
        try {
            $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        if ($InterruptBeforePublish) { Remove-Item -LiteralPath $temporaryPath -Force; return [pscustomobject]@{ Json = $json; published = $false; interrupted = $true } }
        [System.IO.File]::Move($temporaryPath, $finalPath)
        return [pscustomobject]@{ Json = $json; published = $true; interrupted = $false }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("quest-build-profile-self-test-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path (Join-Path $root "app") -Force | Out-Null
        $inside = Resolve-ContainedPath $root "app\output.apk" "fixture"
        $escaped = $false
        try { Resolve-ContainedPath $root "..\outside.apk" "fixture" | Out-Null } catch { $escaped = $true }
        if (-not $inside.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or -not $escaped) { throw "Contained path self-test failed." }
        [ordered]@{ schema = "rusty.morphospace.quest_build_profile_self_test.v2"; status = "passed"; traversal_rejected = $true; modes = @("preflight", "build"); terminal_schema = "rusty.morphospace.quest_build_terminal_result.v1" } | ConvertTo-Json -Depth 8
    } finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

$profile = $null
$execution = $null
$preflight = $null
$terminal = $null
$exitCode = 1
$operation = if ($Mode -ceq "Preflight") { "preflight" } else { "build" }
try {
    if ($Mode -cnotin @("Preflight", "Build")) { throw "Mode must be Preflight or Build." }
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 3600) { throw "TimeoutSeconds must be between 1 and 3600." }
    if (-not $ProfilePath -or -not $ProfileSha256 -or -not $SourceRoot) { throw "ProfilePath, ProfileSha256, and SourceRoot are required." }
    $source = (Resolve-Path -LiteralPath $SourceRoot -ErrorAction Stop).Path
    $profile = Read-BuildProfile $ProfilePath $ProfileSha256 $source
    $execution = Resolve-Execution $profile $ToolPath $ToolSha256
    $environment = Resolve-EnvironmentBindings $profile.Document $EnvironmentBindingsPath $EnvironmentBindingsSha256
    $preflight = Invoke-QuestBuildPreflight $profile $execution $environment $SignerObservationPath $SignerObservationSha256
    if ($operation -ceq "preflight") {
        $terminal = New-TerminalResult "preflight" $preflight.Status $profile $execution $preflight $preflight.ReasonCodes $null $preflight.Payload
        $exitCode = if ($preflight.Status -eq "passed") { 0 } elseif ($preflight.Status -eq "contradiction") { 2 } else { 3 }
    } elseif ($preflight.Status -ne "passed") {
        $terminal = New-TerminalResult "build" $preflight.Status $profile $execution $preflight $preflight.ReasonCodes $null $preflight.Payload
        $exitCode = if ($preflight.Status -eq "contradiction") { 2 } else { 3 }
    } else {
        if (-not $ReceiptPath) { throw "ReceiptPath is required for Build mode." }
        $receiptFullPath = [System.IO.Path]::GetFullPath($ReceiptPath)
        if (Test-Path -LiteralPath $receiptFullPath) { throw "ReceiptPath already exists." }
        $childResults = @(Invoke-ChildProcess $execution $preflight.ChildEnvironment $receiptFullPath $TimeoutSeconds $TestCancelAfterMilliseconds)
        if ($childResults.Count -ne 1) { throw "Child wrapper emitted $($childResults.Count) result objects." }
        $child = $childResults[0]
        $payload = $preflight.Payload
        if ($child.Status -eq "passed") {
            if (-not (Test-Path -LiteralPath $profile.Artifact -PathType Leaf)) { $terminal = New-TerminalResult "build" "failed" $profile $execution $preflight @("artifact-missing") $child.Streams $payload }
            else {
                $artifactInfo = Get-Item -LiteralPath $profile.Artifact
                if ($artifactInfo.Length -le 0) { $terminal = New-TerminalResult "build" "failed" $profile $execution $preflight @("artifact-empty") $child.Streams $payload }
                else {
                    $payload.artifact = [ordered]@{ path = $profile.Artifact; sha256 = Get-Sha256 $profile.Artifact; size_bytes = $artifactInfo.Length }
                    $terminal = New-TerminalResult "build" "passed" $profile $execution $preflight @() $child.Streams $payload
                }
            }
        } else {
            $reason = switch ($child.Status) { "timed_out" { "child-timeout" } "cancelled" { "child-cancelled" } default { "child-exit-nonzero" } }
            $terminal = New-TerminalResult "build" $child.Status $profile $execution $preflight @($reason) $child.Streams $payload
        }
        $exitCode = if ($terminal.terminal_status -eq "passed") { 0 } else { 1 }
    }
} catch {
    $terminalStatus = if ($operation -eq "preflight") { "contradiction" } else { "failed" }
    $reasonCode = if ($operation -eq "preflight") { "preflight-input-invalid" } else { "wrapper-error" }
    $terminal = New-TerminalResult $operation $terminalStatus $profile $execution $preflight @($reasonCode) $null $null
    $exitCode = if ($operation -eq "preflight") { 2 } else { 1 }
}

try {
    $publishPath = if ($operation -eq "build" -and $ReceiptPath) { $ReceiptPath } else { "" }
    $publication = Publish-TerminalResult $terminal $publishPath ([bool]$TestInterruptBeforePublish)
    [Console]::Out.WriteLine($publication.Json)
    if ($publication.interrupted) { $exitCode = 1 }
} catch {
    [Console]::Out.WriteLine((ConvertTo-CompactJson $terminal))
    $exitCode = 1
}
exit $exitCode
