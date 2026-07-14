param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$failures = New-Object System.Collections.Generic.List[string]
$markdownFiles = @(
    Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter "*.md" |
        Where-Object { $_.FullName -notmatch "[\\/]\.git[\\/]" } |
        Sort-Object FullName
)

foreach ($file in $markdownFiles) {
    $content = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($match in [regex]::Matches($content, "!?\[[^\]]*\]\(([^)]+)\)")) {
        $targetText = $match.Groups[1].Value.Trim().Trim('<', '>')
        if (-not $targetText -or $targetText.StartsWith("#") -or $targetText -match "^(https?|mailto):" -or $targetText -match "<[^>]+>") {
            continue
        }
        $targetText = ($targetText -split "#", 2)[0]
        if (-not $targetText) {
            continue
        }
        $targetText = [System.Uri]::UnescapeDataString($targetText).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $target = Join-Path $file.DirectoryName $targetText
        if (-not (Test-Path -LiteralPath $target)) {
            $line = ($content.Substring(0, $match.Index) -split "`n").Count
            $relative = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
            $failures.Add("$relative`:$line -> $($match.Groups[1].Value)")
        }
    }
}

if ($failures.Count -gt 0) {
    throw "Broken relative Markdown links:`n$($failures -join "`n")"
}

Write-Host "Documentation link validation passed for $($markdownFiles.Count) Markdown files."
