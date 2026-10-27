param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
$owner=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceNonpassCustodyCorrection.psm1') -PassThru
&$owner {param($w,$p)
    $candidate=Read-MorphospaceProtocolJson $p
    if([string]$candidate.project_id-cne'envelope-test'-or[string]$candidate.unit_id-cne'u002'){throw 'The path-class fixture refuses non-fixture input.'}
    $frozen=Read-NonpassCustodyTransition $w $candidate.nonpass_custody_defect.freeze
    $old=Read-NonpassCustodyBinding $w ([pscustomobject]@{path=$candidate.predecessor.freeze.receipt_path;sha256=$candidate.predecessor.freeze.receipt_sha256})
    $row=@($candidate.nonpass_custody_defect.artifacts|Where-Object artifact_class -CEQ 'mutable-source')[0]
    # Damage only the decoded scope input to this class boundary. The real
    # immutable owner transaction and its ordinary source blob stay untouched.
    $scope=@($frozen.intent.target.unit.document.allowed_repositories|Where-Object repo_id -CEQ ([string]$row.repo_id))[0]
    $allowed=@($scope.allowed_paths)
    $scope.allowed_paths=@('a-different-writable-root/')
    $resolved=Get-NonpassCustodyArtifactPath $w ([string]$candidate.nonpass_custody_defect.original_receipt.path) ([string]$row.path)
    $caught=$null
    try{Assert-NonpassCustodyPathClass $w $candidate ([pscustomobject]@{intent=$frozen.intent;candidate=$old}) $row $resolved -Observe}catch{$caught=$_}
    if($null-eq$caught){throw 'A frozen regular source blob outside the admitted writable roots was classified audit-inert.'}
    if(-not$caught.Exception.Message.Contains('outside the actual admitted writable paths')){throw $caught}
    $scope.allowed_paths=$allowed
    $map=Read-MorphospaceProtocolJson (Join-Path $w 'repository-map.json');$repo=@($map.repositories|Where-Object repo_id -CEQ ([string]$row.repo_id))[0]
    $root=[IO.Path]::GetFullPath([string]$repo.path);$fixture=[IO.Path]::GetFullPath((Split-Path $w -Parent)).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not$root.StartsWith($fixture,[StringComparison]::OrdinalIgnoreCase)){throw 'The path-class fixture source escaped its disposable root.'}
    $probe=Join-Path $root 'morphospace/[R]EADME.md';$created=$false
    try{
        $stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes('Not an original frozen source blob.');$stream.Write($bytes,0,$bytes.Length);$created=$true}finally{$stream.Dispose()}
        $caught=$null;try{Assert-NonpassCustodyPathClass $w $candidate ([pscustomobject]@{intent=$frozen.intent;candidate=$old}) $row $probe -Observe}catch{$caught=$_}
        if($null-eq$caught){throw 'A Git glob matched a different frozen source blob for an untracked literal filename.'}
        if(-not$caught.Exception.Message.Contains('not an original frozen regular source blob')){throw $caught}
    }finally{if($created){Remove-Item -LiteralPath $probe}}
} $WorkspaceRoot $RequestPath
