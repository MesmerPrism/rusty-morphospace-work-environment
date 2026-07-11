Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function ConvertTo-MorphospaceLowerHex {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $builder=[Text.StringBuilder]::new($Bytes.Length*2)
    foreach($value in $Bytes){[void]$builder.Append($value.ToString('x2',[Globalization.CultureInfo]::InvariantCulture))}
    return $builder.ToString()
}

function Get-MorphospaceSha256Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ConvertTo-MorphospaceLowerHex ($sha.ComputeHash($Bytes))
    } finally {
        $sha.Dispose()
    }
}

function Get-MorphospaceFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) {
        throw "Hash target is missing: $Path"
    }
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ConvertTo-MorphospaceLowerHex ($sha.ComputeHash($stream)) }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Get-MorphospaceStreamSha256 {
    param([Parameter(Mandatory=$true)][IO.Stream]$Stream)
    if(-not$Stream.CanRead-or-not$Stream.CanSeek){throw 'SHA-256 stream must be readable and seekable.'}
    $position=$Stream.Position;$sha=[Security.Cryptography.SHA256]::Create()
    try{$Stream.Position=0;return ConvertTo-MorphospaceLowerHex ($sha.ComputeHash($Stream))}
    finally{$Stream.Position=$position;$sha.Dispose()}
}

function Add-MorphospaceCanonicalJsonString {
    param([string]$Value,[Text.StringBuilder]$Builder)
    [void]$Builder.Append('"')
    foreach($codeUnit in $Value.ToCharArray()){
        $code=[int]$codeUnit
        switch($code){
            8 {[void]$Builder.Append('\b');continue};9 {[void]$Builder.Append('\t');continue}
            10 {[void]$Builder.Append('\n');continue};12 {[void]$Builder.Append('\f');continue};13 {[void]$Builder.Append('\r');continue}
            34 {[void]$Builder.Append('\"');continue};92 {[void]$Builder.Append('\\');continue}
        }
        if($code-lt32-or$code-gt126){[void]$Builder.Append(('\u{0:x4}'-f$code))}else{[void]$Builder.Append($codeUnit)}
    }
    [void]$Builder.Append('"')
}

function Add-MorphospaceCanonicalJsonValue {
    param([AllowNull()][object]$Value,[Text.StringBuilder]$Builder,[int]$Depth=0)
    if($Depth-gt64){throw 'Canonical JSON exceeds depth 64.'}
    if($null-eq$Value){[void]$Builder.Append('null');return}
    if($Value-is[string]-or$Value-is[char]){Add-MorphospaceCanonicalJsonString ([string]$Value) $Builder;return}
    if($Value-is[bool]){[void]$Builder.Append($(if($Value){'true'}else{'false'}));return}
    if($Value-is[byte]-or$Value-is[sbyte]-or$Value-is[int16]-or$Value-is[uint16]-or$Value-is[int32]-or$Value-is[uint32]-or$Value-is[int64]){
        [void]$Builder.Append([Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture));return
    }
    if($Value-is[uint64]){if($Value-gt[long]::MaxValue){throw 'Unsigned JSON integer exceeds Int64.'};[void]$Builder.Append([string]$Value);return}
    if($Value-is[double]-or$Value-is[single]-or$Value-is[decimal]){throw 'Floating-point JSON numbers are not allowed.'}
    if($Value-is[Collections.IDictionary]){
        $keyList=[Collections.Generic.List[string]]::new();foreach($rawKey in $Value.Keys){$keyList.Add([string]$rawKey)};$keys=@($keyList.ToArray());[Array]::Sort($keys,[StringComparer]::Ordinal)
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);[void]$Builder.Append('{');$first=$true
        foreach($key in $keys){if(-not$seen.Add($key)){throw "Case-fold duplicate JSON property '$key'."};if(-not$first){[void]$Builder.Append(',')};$first=$false;Add-MorphospaceCanonicalJsonString $key $Builder;[void]$Builder.Append(':');Add-MorphospaceCanonicalJsonValue $Value[$key] $Builder ($Depth+1)}
        [void]$Builder.Append('}');return
    }
    $propertyList=[Collections.Generic.List[object]]::new();foreach($candidateProperty in $Value.PSObject.Properties){if($candidateProperty.MemberType-in@('NoteProperty','Property','AliasProperty')){$propertyList.Add($candidateProperty)}};$properties=@($propertyList.ToArray())
    if($Value-isnot[Collections.IEnumerable]-and$properties.Count-gt0){
        $map=@{};foreach($property in $properties){$map[[string]$property.Name]=$property.Value};Add-MorphospaceCanonicalJsonValue $map $Builder ($Depth+1);return
    }
    if($Value-is[Collections.IEnumerable]){
        [void]$Builder.Append('[');$first=$true;foreach($item in $Value){if(-not$first){[void]$Builder.Append(',')};$first=$false;Add-MorphospaceCanonicalJsonValue $item $Builder ($Depth+1)};[void]$Builder.Append(']');return
    }
    throw "Unsupported canonical JSON value type '$($Value.GetType().FullName)'."
}

function ConvertTo-MorphospaceCanonicalJson {
    param([Parameter(Mandatory = $true)][object]$Value)
    $builder=[Text.StringBuilder]::new();Add-MorphospaceCanonicalJsonValue $Value $builder 0
    return $builder.ToString()
}

function Get-MorphospaceCanonicalJsonSha256 {
    param([Parameter(Mandatory = $true)][object]$Value)

    $encoding = [System.Text.UTF8Encoding]::new($false)
    return Get-MorphospaceSha256Bytes -Bytes $encoding.GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value))
}

function Skip-MorphospaceJsonWhitespace {
    param([string]$Text,[ref]$Index)
    while($Index.Value-lt$Text.Length-and(' ',"`t","`r","`n")-contains[string]$Text[$Index.Value]){$Index.Value++}
}

function Read-MorphospaceJsonString {
    param([string]$Text,[ref]$Index)
    if($Index.Value-ge$Text.Length-or$Text[$Index.Value]-ne'"'){throw 'Expected JSON string.'};$Index.Value++;$builder=[Text.StringBuilder]::new()
    while($Index.Value-lt$Text.Length){
        $character=$Text[$Index.Value];$Index.Value++
        if($character-eq'"'){return $builder.ToString()}
        if([int]$character-lt32){throw 'Unescaped JSON control character.'}
        if($character-ne'\'){[void]$builder.Append($character);if($builder.Length-gt1048576){throw 'JSON string exceeds 1 MiB.'};continue}
        if($Index.Value-ge$Text.Length){throw 'Truncated JSON escape.'};$escape=$Text[$Index.Value];$Index.Value++
        switch($escape){'"'{[void]$builder.Append('"')};'\'{[void]$builder.Append('\')};'/'{[void]$builder.Append('/')};'b'{[void]$builder.Append([char]8)};'f'{[void]$builder.Append([char]12)};'n'{[void]$builder.Append("`n")};'r'{[void]$builder.Append("`r")};'t'{[void]$builder.Append("`t")};'u'{
            if($Index.Value+4-gt$Text.Length){throw 'Truncated JSON Unicode escape.'};$hex=$Text.Substring($Index.Value,4);if($hex-notmatch'^[0-9a-fA-F]{4}$'){throw 'Invalid JSON Unicode escape.'};$Index.Value+=4;$code=[Convert]::ToInt32($hex,16)
            if($code-ge0xD800-and$code-le0xDBFF){if($Index.Value+6-gt$Text.Length-or$Text.Substring($Index.Value,2)-cne'\u'){throw 'Lone high JSON surrogate.'};$lowHex=$Text.Substring($Index.Value+2,4);if($lowHex-notmatch'^[0-9a-fA-F]{4}$'){throw 'Invalid low JSON surrogate.'};$low=[Convert]::ToInt32($lowHex,16);if($low-lt0xDC00-or$low-gt0xDFFF){throw 'Invalid low JSON surrogate.'};$Index.Value+=6;[void]$builder.Append([char]$code);[void]$builder.Append([char]$low)}elseif($code-ge0xDC00-and$code-le0xDFFF){throw 'Lone low JSON surrogate.'}else{[void]$builder.Append([char]$code)}
        };default{throw "Invalid JSON escape '\$escape'."}}
        if($builder.Length-gt1048576){throw 'JSON string exceeds 1 MiB.'}
    }
    throw 'Unterminated JSON string.'
}

function Read-MorphospaceJsonValue {
    param([string]$Text,[ref]$Index,[int]$Depth)
    if($Depth-gt64){throw 'JSON exceeds depth 64.'};Skip-MorphospaceJsonWhitespace $Text $Index;if($Index.Value-ge$Text.Length){throw 'Unexpected end of JSON.'};$character=$Text[$Index.Value]
    if($character-eq'"'){return Read-MorphospaceJsonString $Text $Index}
    if($character-eq'{'){
        $Index.Value++;$object=[ordered]@{};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);Skip-MorphospaceJsonWhitespace $Text $Index;if($Index.Value-lt$Text.Length-and$Text[$Index.Value]-eq'}'){$Index.Value++;return [pscustomobject]$object}
        while($true){$key=Read-MorphospaceJsonString $Text $Index;if(-not$seen.Add($key)){throw "Duplicate/case-fold JSON property '$key'."};Skip-MorphospaceJsonWhitespace $Text $Index;if($Index.Value-ge$Text.Length-or$Text[$Index.Value]-ne':'){throw 'Expected JSON property colon.'};$Index.Value++;$object[$key]=Read-MorphospaceJsonValue $Text $Index ($Depth+1);Skip-MorphospaceJsonWhitespace $Text $Index;if($Index.Value-ge$Text.Length){throw 'Unterminated JSON object.'};$delimiter=$Text[$Index.Value];$Index.Value++;if($delimiter-eq'}'){break};if($delimiter-ne','){throw 'Expected JSON object comma/close.'};Skip-MorphospaceJsonWhitespace $Text $Index;if($Index.Value-lt$Text.Length-and$Text[$Index.Value]-eq'}'){throw 'Trailing JSON object comma.'}}
        return [pscustomobject]$object
    }
    if($character-eq'['){
        $Index.Value++;$items=[Collections.Generic.List[object]]::new();Skip-MorphospaceJsonWhitespace $Text $Index;if($Index.Value-lt$Text.Length-and$Text[$Index.Value]-eq']'){$Index.Value++;return ,$items.ToArray()}
        while($true){[void]$items.Add((Read-MorphospaceJsonValue $Text $Index ($Depth+1)));Skip-MorphospaceJsonWhitespace $Text $Index;if($Index.Value-ge$Text.Length){throw 'Unterminated JSON array.'};$delimiter=$Text[$Index.Value];$Index.Value++;if($delimiter-eq']'){break};if($delimiter-ne','){throw 'Expected JSON array comma/close.'};Skip-MorphospaceJsonWhitespace $Text $Index;if($Index.Value-lt$Text.Length-and$Text[$Index.Value]-eq']'){throw 'Trailing JSON array comma.'}}
        return ,$items.ToArray()
    }
    foreach($literal in @([pscustomobject]@{text='true';value=$true},[pscustomobject]@{text='false';value=$false},[pscustomobject]@{text='null';value=$null})){if($Text.Substring($Index.Value).StartsWith($literal.text,[StringComparison]::Ordinal)){$Index.Value+=$literal.text.Length;return $literal.value}}
    $remaining=$Text.Substring($Index.Value);$match=[regex]::Match($remaining,'^-?(?:0|[1-9][0-9]*)')
    if(-not$match.Success){throw "Invalid JSON token at offset $($Index.Value)."};$token=$match.Value;$Index.Value+=$token.Length;if($Index.Value-lt$Text.Length-and' ',"`t","`r","`n",',',']','}'-notcontains[string]$Text[$Index.Value]){throw 'Floating/exponent/invalid JSON number.'}
    $number=[long]0;if(-not[long]::TryParse($token,[Globalization.NumberStyles]::AllowLeadingSign,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){throw 'JSON integer exceeds Int64.'};return $number
}

function ConvertFrom-MorphospaceProtocolJsonBytes {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
        [string]$Context = "protocol JSON"
    )
    try {
        if ($Bytes.Length -gt 16777216) { throw "Protocol JSON exceeds the 16 MiB safety bound." }
        if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) {
            throw "UTF-8 BOM is not allowed in protocol JSON."
        }
        if ($Bytes -contains 0) { throw "NUL bytes are not allowed in protocol JSON." }
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $text = $encoding.GetString($Bytes)
        $index=0;$value=Read-MorphospaceJsonValue $text ([ref]$index) 0;Skip-MorphospaceJsonWhitespace $text ([ref]$index)
        if($index-ne$text.Length){throw "Trailing JSON content at offset $index."}
        if($value-isnot[pscustomobject]){throw 'Top-level protocol JSON must be an object.'}
        return $value
    } catch {
        throw "Invalid JSON in $Context`: $($_.Exception.Message)"
    }
}

function Read-MorphospaceProtocolJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) { throw "Required JSON file is missing: $Path" }
    return ConvertFrom-MorphospaceProtocolJsonBytes -Bytes ([System.IO.File]::ReadAllBytes($fullPath)) -Context "'$Path'"
}

function Get-MorphospacePendingSiblingClassificationInternal {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    $target = [System.IO.Path]::GetFullPath($TargetPath)
    $parent = [System.IO.Path]::GetDirectoryName($target)
    $targetName = [System.IO.Path]::GetFileName($target)
    $prefix = "$targetName.pending-"
    $exact = [Collections.Generic.List[string]]::new()
    $hostile = [Collections.Generic.List[string]]::new()
    if ($parent -and [System.IO.Directory]::Exists($parent)) {
        $pattern = '^' + [regex]::Escape($targetName) + '\.pending-[0-9a-f]{32}$'
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($parent)) {
            $leaf = [System.IO.Path]::GetFileName($entry)
            if (-not $leaf.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $attributes = [System.IO.File]::GetAttributes($entry)
            if ($leaf -cmatch $pattern -and
                ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0 -and
                ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                $exact.Add([System.IO.Path]::GetFullPath($entry))
            } else {
                $hostile.Add([System.IO.Path]::GetFullPath($entry))
            }
        }
    }
    $exactArray = @($exact.ToArray()); [Array]::Sort($exactArray, [StringComparer]::Ordinal)
    $hostileArray = @($hostile.ToArray()); [Array]::Sort($hostileArray, [StringComparer]::Ordinal)
    return [pscustomobject]@{ target=$target; exact=@($exactArray); hostile=@($hostileArray) }
}

function Write-MorphospaceProtocolJsonAtomicInternal {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [switch]$NoOverwrite
    )

    $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    if ($NoOverwrite -and [System.IO.File]::Exists($Path)) {
        throw "Managed control artifact already exists and will not be overwritten: $Path"
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value) + "`n")
    if ($bytes.Length -gt 16777216) { throw "Managed protocol JSON exceeds 16 MiB: $Path" }
    if ($NoOverwrite) {
        $priorPending = Get-MorphospacePendingSiblingClassificationInternal -TargetPath $Path
        if ($priorPending.hostile.Count -gt 0 -or $priorPending.exact.Count -gt 0) {
            throw "Managed control artifact has unresolved same-directory pending state: $Path"
        }
        $temporary = "$Path.pending-$([guid]::NewGuid().ToString('N'))"
        $stream = [System.IO.FileStream]::new(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        $pendingLease = [System.IO.FileStream]::new($temporary, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete))
        try {
            $expectedHash = Get-MorphospaceSha256Bytes -Bytes $bytes
            if ($pendingLease.Length -ne $bytes.Length -or (Get-MorphospaceStreamSha256 $pendingLease) -cne $expectedHash) {
                throw "Managed control artifact failed pending-write readback; pending bytes were preserved: $temporary"
            }
            $currentPending = Get-MorphospacePendingSiblingClassificationInternal -TargetPath $Path
            if ($currentPending.hostile.Count -gt 0 -or $currentPending.exact.Count -ne 1 -or
                -not $currentPending.exact[0].Equals([System.IO.Path]::GetFullPath($temporary), [System.StringComparison]::Ordinal)) {
                throw "Managed control artifact pending sibling state changed; pending bytes were preserved: $temporary"
            }
            try { [System.IO.File]::Move($temporary, $Path) }
            catch { throw "Managed control artifact atomic no-replace publication failed; pending bytes were preserved when still present: $temporary`n$($_.Exception.Message)" }
            $publishedLease = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                if ($publishedLease.Length -ne $bytes.Length -or (Get-MorphospaceStreamSha256 $publishedLease) -cne $expectedHash) {
                    throw "Managed control artifact publication readback changed: $Path"
                }
            } finally { $publishedLease.Dispose() }
        } finally { $pendingLease.Dispose() }
        return
    }

    $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    $stream = [System.IO.FileStream]::new($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temporary, $Path, $null) }
    else { [System.IO.File]::Move($temporary, $Path) }
}

function Write-MorphospaceManagedProtocolJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][object]$Value,
        [switch]$NoOverwrite
    )
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath
    Write-MorphospaceProtocolJsonAtomicInternal -Path $path -Value $Value -NoOverwrite:$NoOverwrite
}

function ConvertTo-MorphospaceProtocolRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -cne $Path.Trim()) { throw "Relative path has leading or trailing whitespace: $Path" }
    if ($Path -cne $Path.Normalize([Text.NormalizationForm]::FormC)) { throw "Relative path must use Unicode NFC normalization: $Path" }
    $normalized = $Path.Replace("\", "/")
    while ($normalized.StartsWith("./")) { $normalized = $normalized.Substring(2) }
    if (-not $normalized -or [System.IO.Path]::IsPathRooted($normalized)) {
        throw "Expected a non-rooted relative path, received '$Path'."
    }
    foreach($pathSegment in $normalized.Split('/')){if($pathSegment-ceq'..'){throw "Relative path may not contain '..': $Path"}}
    foreach ($segment in $normalized.Split("/")) {
        if (-not $segment -or $segment -eq "." -or $segment.Contains(":")) {
            throw "Relative path contains an empty, dot, or alternate-stream segment: $Path"
        }
        if ($segment.EndsWith(" ") -or $segment.EndsWith(".") -or $segment -match '~[0-9]') {
            throw "Relative path contains a non-canonical Windows alias segment: $Path"
        }
        if ($segment.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $segment -match '[\x00-\x1f]') {
            throw "Relative path contains invalid/control characters: $Path"
        }
        $stem = ($segment -split '\.')[0].ToUpperInvariant()
        if ($stem -in @('CON','PRN','AUX','NUL','COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9','LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')) {
            throw "Relative path contains a reserved DOS device name: $Path"
        }
    }
    return $normalized
}

function Assert-MorphospaceNoReparseAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $rootVolume = [System.IO.Path]::GetPathRoot($rootPath)
    if($rootPath.Length-gt$rootVolume.Length){$rootPath=$rootPath.TrimEnd('\','/')}
    $candidatePath = [System.IO.Path]::GetFullPath($Candidate)
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.Equals($rootPath,[System.StringComparison]::OrdinalIgnoreCase) -and -not $candidatePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate path is outside its declared root: $Candidate"
    }
    $filesystemRoot=[System.IO.Path]::GetPathRoot($candidatePath)
    if(-not$filesystemRoot){throw "Candidate path has no filesystem root: $Candidate"}
    $current=$filesystemRoot.TrimEnd('\','/')+[System.IO.Path]::DirectorySeparatorChar
    if([System.IO.Directory]::Exists($current)-or[System.IO.File]::Exists($current)){
        $rootAttributes=[System.IO.File]::GetAttributes($current)
        if(($rootAttributes-band[System.IO.FileAttributes]::ReparsePoint)-ne0){throw "Filesystem root is a reparse point: $current"}
    }
    $relative=$candidatePath.Substring($filesystemRoot.Length).Replace('\','/')
    foreach ($segment in $relative.Split('/')) {
        if (-not $segment) { continue }
        $current = [System.IO.Path]::Combine($current, $segment)
        if (-not ([System.IO.Directory]::Exists($current) -or [System.IO.File]::Exists($current))) { break }
        $attributes = [System.IO.File]::GetAttributes($current)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse-point ancestors are not accepted for protocol paths: $current"
        }
    }
}

function Resolve-MorphospaceWorkspacePath {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [switch]$RequireLeaf
    )

    $relative = ConvertTo-MorphospaceProtocolRelativePath -Path $RelativePath
    $root = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd("\", "/")
    $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $relative))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the project workspace: $RelativePath"
    }
    Assert-MorphospaceNoReparseAncestor -Root $root -Candidate $candidate
    if ($RequireLeaf -and -not [System.IO.File]::Exists($candidate)) {
        throw "Workspace artifact is missing: $RelativePath"
    }
    return $candidate
}

function Get-MorphospaceManagedControlPath {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$UnitId,
        [Parameter(Mandatory = $true)][ValidateSet(
            "inflight-adoption", "claim-action", "claim-correction", "ownership",
            "legacy-prefix-anchor", "protocol-state", "validation-evidence",
            "validation-receipt", "validation-action", "accept-action"
        )][string]$Role,
        [string]$AttemptId = ""
    )

    if ($UnitId -notmatch '^[a-z0-9][a-z0-9-]{1,63}$') {
        throw "Invalid unit ID for a managed control path: $UnitId"
    }
    $names = @{
        "inflight-adoption" = "$UnitId-inflight-adoption.json"
        "claim-action" = "$UnitId-claim-action.json"
        "claim-correction" = "$UnitId-claim-correction.json"
        "ownership" = "$UnitId-unit-ownership.json"
        "legacy-prefix-anchor" = "$UnitId-legacy-event-prefix-anchor.json"
        "protocol-state" = "$UnitId-current-unit-protocol.json"
        "validation-evidence" = "evidence.json"
        "validation-receipt" = "validation-receipt-v2.json"
        "validation-action" = "validation-action.json"
        "accept-action" = "accept-action.json"
    }
    $attemptRoles = @("validation-evidence", "validation-receipt", "validation-action", "accept-action")
    if ($attemptRoles -contains $Role) {
        if ($AttemptId -notmatch '^[a-z0-9][a-z0-9-]{7,95}$') {
            throw "Validation managed paths require an automation-derived attempt ID."
        }
        $relative = "receipts/$UnitId/$AttemptId/$($names[$Role])"
    } else {
        if ($AttemptId) { throw "AttemptId is not valid for one-time managed role '$Role'." }
        $relative = "receipts/$($names[$Role])"
    }
    return [pscustomobject][ordered]@{
        role = $Role
        relative_path = $relative
        absolute_path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $relative
    }
}

function ConvertTo-MorphospaceUtcTimestamp {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$Value)

    return $Value.ToUniversalTime().ToString(
        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function ConvertFrom-MorphospaceInvariantTimestamp {
    param([Parameter(Mandatory = $true)][string]$Value)

    [string[]]$formats = @(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
        "yyyy-MM-dd'T'HH:mm:sszzz",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFzzz",
        "o"
    )
    $parsed = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParseExact(
        $Value,
        $formats,
        [System.Globalization.CultureInfo]::InvariantCulture,
        ([System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal),
        [ref]$parsed
    )
    if (-not $ok) { throw "Timestamp is not an accepted invariant ISO-8601 value: $Value" }
    return $parsed.ToUniversalTime()
}

function Test-MorphospaceStrictUtcTimestamp {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') {
        throw "Current-unit timestamps must use seven-digit UTC ISO-8601 form: $Value"
    }
    return ConvertFrom-MorphospaceInvariantTimestamp -Value $Value
}

function New-MorphospaceRunId {
    param([Parameter(Mandatory = $true)][string]$UnitId)

    return "$UnitId-$([guid]::NewGuid().ToString('N'))"
}

function Enter-MorphospaceWorkspaceMutex {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )
    $normalized = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/').ToUpperInvariant()
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $id = Get-MorphospaceSha256Bytes $utf8.GetBytes($normalized)
    $mutex = [System.Threading.Mutex]::new($false, "Local\RustyMorphospace-$id")
    $acquired = $false
    $abandoned = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true; $abandoned = $true }
        if (-not $acquired) { throw "Timed out waiting for the exclusive workspace protocol lock." }
        return [pscustomobject]@{ mutex=$mutex; acquired=$true; abandoned=$abandoned; name="Local\RustyMorphospace-$id" }
    } catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

function Exit-MorphospaceWorkspaceMutex {
    param([Parameter(Mandatory = $true)][object]$Lock)
    if ($Lock.acquired) { try { $Lock.mutex.ReleaseMutex() } finally { $Lock.mutex.Dispose() } }
}

function Assert-MorphospaceExactPropertySet {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [string[]]$Optional = @(),
        [Parameter(Mandatory = $true)][string]$Context
    )

    $actualList=[Collections.Generic.List[string]]::new();foreach($property in $Value.PSObject.Properties){$actualList.Add([string]$property.Name)};$actual=@($actualList.ToArray())
    $allowedSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($name in @($Required)+@($Optional)){[void]$allowedSet.Add([string]$name)}
    $actualSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($name in $actual){if(-not$actualSet.Add($name)){throw "$Context repeats exact property '$name'."}}
    $missingList=[Collections.Generic.List[string]]::new();foreach($requiredName in $Required){if(-not$actualSet.Contains([string]$requiredName)){$missingList.Add([string]$requiredName)}};$missing=@($missingList.ToArray())
    $extraList=[Collections.Generic.List[string]]::new();foreach($actualName in $actual){if(-not$allowedSet.Contains([string]$actualName)){$extraList.Add([string]$actualName)}};$extra=@($extraList.ToArray())
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw "$Context has a damaged property set (missing=$($missing -join ','), extra=$($extra -join ','))."
    }
}

function New-MorphospaceTypedFileReference {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSchema,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $absolute = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $RelativePath -RequireLeaf
    $document = Read-MorphospaceProtocolJson -Path $absolute
    if ([string]$document.schema -cne $ExpectedSchema) {
        throw "Typed receipt '$RelativePath' has schema '$([string]$document.schema)', expected '$ExpectedSchema'."
    }
    return [pscustomobject][ordered]@{
        role = $Role
        path = (ConvertTo-MorphospaceProtocolRelativePath -Path $RelativePath)
        schema = $ExpectedSchema
        sha256 = Get-MorphospaceFileSha256 -Path $absolute
    }
}

function Read-MorphospaceTypedFileSnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
        [Parameter(Mandatory=$true)][object]$Reference,
        [Parameter(Mandatory=$true)][string]$Context,
        [switch]$KeepLease
    )
    Assert-MorphospaceExactPropertySet $Reference @('role','path','schema','sha256') @() $Context
    if([string]$Reference.sha256 -notmatch '^[0-9a-f]{64}$'){throw "$Context has an invalid SHA-256."}
    $path=Resolve-MorphospaceWorkspacePath $WorkspaceRoot ([string]$Reference.path) -RequireLeaf
    $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length-gt16777216){throw "$Context exceeds 16 MiB."};$bytes=[byte[]]::new([int]$stream.Length);$read=0;while($read-lt$bytes.Length){$n=$stream.Read($bytes,$read,$bytes.Length-$read);if($n-le0){throw "$Context short read."};$read+=$n}
        if((Get-MorphospaceSha256Bytes $bytes)-cne[string]$Reference.sha256){throw "$Context content hash changed."}
        $document=ConvertFrom-MorphospaceProtocolJsonBytes $bytes $Context;if([string]$document.schema-cne[string]$Reference.schema){throw "$Context schema binding changed."}
        $result=[pscustomobject]@{path=$path;document=$document;bytes=$bytes;stream=if($KeepLease){$stream}else{$null}}
        if($KeepLease){$stream=$null};return $result
    }finally{if($null-ne$stream){$stream.Dispose()}}
}

# Private deterministic publication primitive for trust-bound authorizations,
# action/transition intents, and recovery completions. Higher authorities may
# invoke it inside this module after validating their own authority contract;
# callers never need a chain of recovery authorizations for its partial files.
function Repair-MorphospaceDeterministicCanonicalJsonInternal {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][object]$Value,
        [switch]$KeepLease
    )

    $relative = ConvertTo-MorphospaceProtocolRelativePath -Path $RelativePath
    if (-not $relative.StartsWith('receipts/', [System.StringComparison]::Ordinal)) {
        throw "Deterministic authority artifacts must use managed receipt paths: $relative"
    }
    $path = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $relative
    $parent = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    Assert-MorphospaceNoReparseAncestor -Root ([System.IO.Path]::GetFullPath($WorkspaceRoot)) -Candidate $path
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $expectedBytes = $encoding.GetBytes((ConvertTo-MorphospaceCanonicalJson -Value $Value) + "`n")
    if ($expectedBytes.Length -gt 16777216) { throw "Deterministic authority artifact exceeds 16 MiB: $relative" }
    $expectedHash = Get-MorphospaceSha256Bytes -Bytes $expectedBytes
    $stream = $null
    $created = $false
    try {
        try {
            $stream = [System.IO.FileStream]::new(
                $path,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None,
                4096,
                [System.IO.FileOptions]::WriteThrough
            )
            $created = $true
        } catch [System.IO.IOException] {
            $stream = [System.IO.FileStream]::new(
                $path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None,
                4096,
                [System.IO.FileOptions]::WriteThrough
            )
        }
        $existingLength = [long]$stream.Length
        if ($existingLength -gt $expectedBytes.Length) {
            throw "Deterministic authority artifact has extra bytes and will not be truncated: $relative"
        }
        $stream.Position = 0
        $buffer = [byte[]]::new(8192)
        $verified = [long]0
        while ($verified -lt $existingLength) {
            $wanted = [int][Math]::Min($buffer.Length, $existingLength - $verified)
            $read = $stream.Read($buffer, 0, $wanted)
            if ($read -ne $wanted) { throw "Deterministic authority artifact produced a short prefix read: $relative" }
            for ($index = 0; $index -lt $read; $index++) {
                if ($buffer[$index] -ne $expectedBytes[[int]($verified + $index)]) {
                    throw "Deterministic authority artifact diverges from its exact canonical prefix: $relative"
                }
            }
            $verified += $read
        }
        if ($existingLength -lt $expectedBytes.Length) {
            $stream.Position = $existingLength
            $remaining = $expectedBytes.Length - [int]$existingLength
            $stream.Write($expectedBytes, [int]$existingLength, $remaining)
            $stream.Flush($true)
        } elseif ($created) {
            $stream.Flush($true)
        }
        if ($stream.Length -ne $expectedBytes.Length -or (Get-MorphospaceStreamSha256 $stream) -cne $expectedHash) {
            throw "Deterministic authority artifact failed exact post-repair verification: $relative"
        }
        $result = [pscustomobject]@{
            relative_path = $relative
            absolute_path = $path
            sha256 = $expectedHash
            length = [long]$expectedBytes.Length
            document = $Value
            stream = if ($KeepLease) { $stream } else { $null }
        }
        if ($KeepLease) { $stream = $null }
        return $result
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-MorphospacePendingObservation {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRelativePath,
        [switch]$KeepLease
    )

    $targetRelative = ConvertTo-MorphospaceProtocolRelativePath -Path $TargetRelativePath
    if (-not $targetRelative.StartsWith('receipts/', [System.StringComparison]::Ordinal) -or
        $targetRelative.StartsWith('receipts/pending-quarantine/', [System.StringComparison]::Ordinal)) {
        throw "Pending recovery targets must be ordinary managed receipt paths: $targetRelative"
    }
    $target = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $targetRelative
    $classification = Get-MorphospacePendingSiblingClassificationInternal -TargetPath $target
    if ($classification.hostile.Count -gt 0) {
        throw "Hostile or non-canonical pending sibling blocks recovery: $($classification.hostile -join ', ')"
    }
    if ($classification.exact.Count -gt 1) {
        throw "Multiple exact pending siblings block recovery for '$targetRelative'."
    }
    $targetExists = [System.IO.File]::Exists($target) -or [System.IO.Directory]::Exists($target)
    $candidate = $null
    $stream = $null
    try {
        if ($classification.exact.Count -eq 1) {
            $pendingPath = [string]$classification.exact[0]
            Assert-MorphospaceNoReparseAncestor -Root ([System.IO.Path]::GetFullPath($WorkspaceRoot)) -Candidate $pendingPath
            $stream = [System.IO.FileStream]::new(
                $pendingPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete)
            )
            if ($stream.Length -gt 16777216) { throw "Pending recovery source exceeds 16 MiB: $pendingPath" }
            $recheck = Get-MorphospacePendingSiblingClassificationInternal -TargetPath $target
            if ($recheck.hostile.Count -gt 0 -or $recheck.exact.Count -ne 1 -or
                -not ([string]$recheck.exact[0]).Equals($pendingPath, [System.StringComparison]::Ordinal)) {
                throw "Pending sibling state changed while acquiring its evidence lease."
            }
            $pendingRelative = $pendingPath.Substring([System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/').Length + 1).Replace('\','/')
            $candidate = [pscustomobject]@{
                relative_path = ConvertTo-MorphospaceProtocolRelativePath -Path $pendingRelative
                absolute_path = $pendingPath
                length = [long]$stream.Length
                sha256 = Get-MorphospaceStreamSha256 -Stream $stream
                stream = if ($KeepLease) { $stream } else { $null }
            }
            if ($KeepLease) { $stream = $null }
        }
        return [pscustomobject]@{
            target_relative_path = $targetRelative
            target_absolute_path = $target
            target_exists = $targetExists
            candidate = $candidate
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-MorphospacePendingQuarantineCompletionInternal {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][object]$AuthorizationReference,
        [Parameter(Mandatory = $true)][object]$Authorization,
        [Parameter(Mandatory = $true)][string]$QuarantineRelativePath
    )

    Assert-MorphospaceExactPropertySet $Document @('schema','authorization','completed_at','project_id','unit_id','target_path','pending','quarantine_path','status') @() 'Pending quarantine completion'
    if ([string]$Document.schema -cne 'rusty.morphospace.workflow.pending_quarantine_completion.v1') { throw 'Pending quarantine completion has the wrong schema.' }
    [void](Test-MorphospaceStrictUtcTimestamp ([string]$Document.completed_at))
    if ([string]$Document.project_id -cne [string]$Authorization.project_id -or
        [string]$Document.unit_id -cne [string]$Authorization.unit_id -or
        [string]$Document.target_path -cne [string]$Authorization.target_path -or
        [string]$Document.quarantine_path -cne $QuarantineRelativePath -or
        [string]$Document.status -cne 'quarantined-preserved') {
        throw 'Pending quarantine completion is not bound to the authorized operation.'
    }
    Assert-MorphospaceExactPropertySet $Document.authorization @('role','path','schema','sha256') @() 'Pending quarantine completion authorization reference'
    if ((Get-MorphospaceCanonicalJsonSha256 $Document.authorization) -cne (Get-MorphospaceCanonicalJsonSha256 $AuthorizationReference)) {
        throw 'Pending quarantine completion authorization reference changed.'
    }
    Assert-MorphospaceExactPropertySet $Document.pending @('path','sha256','length') @() 'Pending quarantine completion source'
    if ([string]$Document.pending.path -cne [string]$Authorization.pending_path -or
        [string]$Document.pending.sha256 -cne [string]$Authorization.pending_sha256 -or
        [long]$Document.pending.length -ne [long]$Authorization.pending_length) {
        throw 'Pending quarantine completion source binding changed.'
    }
}

function Invoke-MorphospacePendingQuarantineRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][object]$AuthorizationReference
    )

    Assert-MorphospaceExactPropertySet $AuthorizationReference @('role','path','schema','sha256') @() 'Pending quarantine authorization reference'
    if ([string]$AuthorizationReference.role -cne 'pending-quarantine-authorization' -or
        [string]$AuthorizationReference.schema -cne 'rusty.morphospace.workflow.pending_quarantine_authorization.v1') {
        throw 'Pending recovery requires an exact typed quarantine authorization reference.'
    }
    $authorizationSnapshot = Read-MorphospaceTypedFileSnapshot -WorkspaceRoot $WorkspaceRoot -Reference $AuthorizationReference -Context 'Pending quarantine authorization' -KeepLease
    $pendingLease = $null
    $quarantineLease = $null
    $completionLease = $null
    try {
        $authorization = $authorizationSnapshot.document
        Assert-MorphospaceExactPropertySet $authorization @('schema','authorization_id','created_at','project_id','unit_id','action','target_path','pending_path','pending_sha256','pending_length','quarantine_path','status') @() 'Pending quarantine authorization'
        if ([string]$authorization.schema -cne 'rusty.morphospace.workflow.pending_quarantine_authorization.v1' -or
            [string]$authorization.action -cne 'quarantine-preserve' -or [string]$authorization.status -cne 'authorized') {
            throw 'Pending quarantine authorization has an invalid schema/action/status.'
        }
        if ([string]$authorization.authorization_id -notmatch '^[a-z0-9][a-z0-9-]{7,95}$' -or
            [string]$authorization.project_id -notmatch '^[a-z0-9][a-z0-9-]{1,191}$' -or
            [string]$authorization.unit_id -notmatch '^[a-z0-9][a-z0-9-]{1,63}$') {
            throw 'Pending quarantine authorization has an invalid identifier.'
        }
        [void](Test-MorphospaceStrictUtcTimestamp ([string]$authorization.created_at))
        if ([string]$authorization.pending_sha256 -notmatch '^[0-9a-f]{64}$' -or [long]$authorization.pending_length -lt 0 -or [long]$authorization.pending_length -gt 16777216) {
            throw 'Pending quarantine authorization has an invalid source hash/length.'
        }
        $targetRelative = ConvertTo-MorphospaceProtocolRelativePath ([string]$authorization.target_path)
        $pendingRelative = ConvertTo-MorphospaceProtocolRelativePath ([string]$authorization.pending_path)
        $quarantineRelative = ConvertTo-MorphospaceProtocolRelativePath ([string]$authorization.quarantine_path)
        if ($targetRelative -cne [string]$authorization.target_path -or $pendingRelative -cne [string]$authorization.pending_path -or $quarantineRelative -cne [string]$authorization.quarantine_path) {
            throw 'Pending quarantine authorization paths are not canonical.'
        }
        $targetLeaf = [System.IO.Path]::GetFileName($targetRelative)
        if ($targetLeaf.IndexOf('.pending-', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'A pending artifact cannot itself be a recovery publication target.' }
        $pendingLeaf = [System.IO.Path]::GetFileName($pendingRelative)
        $expectedPendingPattern = '^' + [regex]::Escape($targetLeaf) + '\.pending-[0-9a-f]{32}$'
        $targetParent = [System.IO.Path]::GetDirectoryName($targetRelative).Replace('\','/')
        $expectedPendingRelative = $(if ($targetParent) { "$targetParent/$pendingLeaf" } else { $pendingLeaf })
        if ($pendingLeaf -cnotmatch $expectedPendingPattern -or $pendingRelative -cne $expectedPendingRelative) {
            throw 'Pending quarantine authorization does not bind one exact same-directory pending source.'
        }
        $baseRelative = "receipts/pending-quarantine/$([string]$authorization.unit_id)/$([string]$authorization.authorization_id)"
        $expectedAuthorizationPath = "$baseRelative/authorization.json"
        $expectedQuarantinePath = "$baseRelative/$pendingLeaf.preserved"
        $completionRelative = "$baseRelative/completion.json"
        if ([string]$AuthorizationReference.path -cne $expectedAuthorizationPath -or $quarantineRelative -cne $expectedQuarantinePath) {
            throw 'Pending quarantine authorization is not stored at, or does not name, its canonical recovery paths.'
        }

        $observation = Get-MorphospacePendingObservation -WorkspaceRoot $WorkspaceRoot -TargetRelativePath $targetRelative -KeepLease
        if ($observation.target_exists) { throw 'Published target coexists with pending recovery state.' }
        if ($null -ne $observation.candidate) { $pendingLease = $observation.candidate.stream }
        $quarantinePath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $quarantineRelative
        $completionPath = Resolve-MorphospaceWorkspacePath -WorkspaceRoot $WorkspaceRoot -RelativePath $completionRelative
        $quarantineExists = [System.IO.File]::Exists($quarantinePath)
        $completionExists = [System.IO.File]::Exists($completionPath)

        if ($null -ne $observation.candidate) {
            if ([string]$observation.candidate.relative_path -cne $pendingRelative -or
                [long]$observation.candidate.length -ne [long]$authorization.pending_length -or
                [string]$observation.candidate.sha256 -cne [string]$authorization.pending_sha256) {
                throw 'Pending recovery source does not match its authorization.'
            }
            if ($quarantineExists -or $completionExists) { throw 'Pending recovery source coexists with preplanted quarantine/completion state.' }
            $quarantineParent = [System.IO.Path]::GetDirectoryName($quarantinePath)
            if (-not [System.IO.Directory]::Exists($quarantineParent)) { [void][System.IO.Directory]::CreateDirectory($quarantineParent) }
            Assert-MorphospaceNoReparseAncestor -Root ([System.IO.Path]::GetFullPath($WorkspaceRoot)) -Candidate $quarantinePath
            [System.IO.File]::Move([string]$observation.candidate.absolute_path, $quarantinePath)
            $quarantineExists = $true
        } elseif (-not $quarantineExists) {
            throw 'Authorized pending recovery source and preserved quarantine artifact are both absent.'
        }

        $quarantineLease = [System.IO.FileStream]::new($quarantinePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        if ($quarantineLease.Length -ne [long]$authorization.pending_length -or
            (Get-MorphospaceStreamSha256 $quarantineLease) -cne [string]$authorization.pending_sha256) {
            throw 'Preserved quarantine artifact does not match the authorized source bytes.'
        }
        if ([System.IO.File]::Exists($observation.target_absolute_path)) { throw 'Published target appeared during pending recovery.' }

        $completionDocument = [pscustomobject][ordered]@{
            schema = 'rusty.morphospace.workflow.pending_quarantine_completion.v1'
            authorization = $AuthorizationReference
            completed_at = [string]$authorization.created_at
            project_id = [string]$authorization.project_id
            unit_id = [string]$authorization.unit_id
            target_path = $targetRelative
            pending = [pscustomobject][ordered]@{ path=$pendingRelative; sha256=[string]$authorization.pending_sha256; length=[long]$authorization.pending_length }
            quarantine_path = $quarantineRelative
            status = 'quarantined-preserved'
        }
        $completionRepair = Repair-MorphospaceDeterministicCanonicalJsonInternal -WorkspaceRoot $WorkspaceRoot -RelativePath $completionRelative -Value $completionDocument -KeepLease
        $completionLease = $completionRepair.stream
        Test-MorphospacePendingQuarantineCompletionInternal $completionDocument $AuthorizationReference $authorization $quarantineRelative
        if ([System.IO.File]::Exists($observation.target_absolute_path) -or [System.IO.File]::Exists((Resolve-MorphospaceWorkspacePath $WorkspaceRoot $pendingRelative))) {
            throw 'Pending recovery final boundary contains a publication target or source artifact.'
        }
        if ($quarantineLease.Length -ne [long]$authorization.pending_length -or (Get-MorphospaceStreamSha256 $quarantineLease) -cne [string]$authorization.pending_sha256) {
            throw 'Preserved quarantine bytes changed before recovery completion.'
        }
        $completionReference = [pscustomobject][ordered]@{
            role = 'pending-quarantine-completion'
            path = $completionRelative
            schema = 'rusty.morphospace.workflow.pending_quarantine_completion.v1'
            sha256 = [string]$completionRepair.sha256
        }
        return [pscustomobject]@{ status='quarantined-preserved'; quarantine_path=$quarantineRelative; completion=$completionDocument; completion_reference=$completionReference }
    } finally {
        if ($null -ne $completionLease) { $completionLease.Dispose() }
        if ($null -ne $quarantineLease) { $quarantineLease.Dispose() }
        if ($null -ne $pendingLease) { $pendingLease.Dispose() }
        if ($null -ne $authorizationSnapshot.stream) { $authorizationSnapshot.stream.Dispose() }
    }
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function `
    Get-MorphospaceSha256Bytes, Get-MorphospaceFileSha256, Get-MorphospaceStreamSha256, `
    ConvertTo-MorphospaceCanonicalJson, Get-MorphospaceCanonicalJsonSha256, `
        Read-MorphospaceProtocolJson, ConvertFrom-MorphospaceProtocolJsonBytes, Write-MorphospaceManagedProtocolJsonAtomic, `
    ConvertTo-MorphospaceProtocolRelativePath, Resolve-MorphospaceWorkspacePath, `
    Get-MorphospaceManagedControlPath, ConvertTo-MorphospaceUtcTimestamp, `
    ConvertFrom-MorphospaceInvariantTimestamp, Test-MorphospaceStrictUtcTimestamp, `
    New-MorphospaceRunId, Enter-MorphospaceWorkspaceMutex, Exit-MorphospaceWorkspaceMutex, Assert-MorphospaceExactPropertySet, `
    New-MorphospaceTypedFileReference, Read-MorphospaceTypedFileSnapshot, Assert-MorphospaceNoReparseAncestor
