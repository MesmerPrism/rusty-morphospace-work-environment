param(
    [string]$Root = "."
)

$ErrorActionPreference = "Stop"

$resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
$selfPath = if ($MyInvocation.MyCommand.Path) {
    (Resolve-Path -LiteralPath $MyInvocation.MyCommand.Path).Path
} else {
    ""
}

$failPatterns = @(
    [ordered]@{ Name = "windows-drive-path"; Pattern = "(?<![A-Za-z])\b[A-Za-z]:[\\/]" },
    [ordered]@{ Name = "windows-user-home"; Pattern = "C:[\\/]Users[\\/]" },
    [ordered]@{ Name = "agent-bureau"; Pattern = "Agent Bureau" },
    [ordered]@{ Name = "private-planning-repo"; Pattern = "Private-Planning" },
    [ordered]@{ Name = "private-package-prefix"; Pattern = "io\.github\.mesmerprism\.[A-Za-z0-9_.-]+" },
    [ordered]@{ Name = "known-private-project"; Pattern = "Viscereality|Rusty-Kuramoto|Rusty-Vision" }
)

$warnPatterns = @(
    [ordered]@{ Name = "possible-device-serial"; Pattern = "\b(?=[A-Z0-9]{12,20}\b)(?=[A-Z0-9]*\d)[A-Z0-9]{12,20}\b" },
    [ordered]@{ Name = "possible-key-material"; Pattern = "(?i)\b(api[_-]?key|access[_-]?token|-----BEGIN [A-Z ]*PRIVATE KEY-----)\b" }
)

$insideGit = @(& git -C $resolvedRoot rev-parse --is-inside-work-tree 2>$null)
if ($LASTEXITCODE -eq 0 -and ($insideGit -join "").Trim() -eq "true") {
    $files = @(& git -C $resolvedRoot ls-files --cached --others --exclude-standard | ForEach-Object {
        $candidate = Join-Path $resolvedRoot ([string]$_)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate -Force }
    })
} else {
    $files = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Force |
        Where-Object {
            $_.FullName -notmatch "[\\/]\.git[\\/]" -and
            $_.FullName -notmatch "[\\/]artifacts[\\/]" -and
            $_.FullName -notmatch "[\\/]local[\\/]" -and
            $_.FullName -notmatch "[\\/]target[\\/]" -and
            $_.FullName -notmatch "[\\/]build[\\/]" -and
            $_.FullName -ine $selfPath
        })
}
$files = @($files | Where-Object { $_.FullName -ine $selfPath })

$failures = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[object]

foreach ($file in $files) {
    $text = ""
    try {
        $text = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction Stop
    } catch {
        continue
    }
    if ($null -eq $text) { continue }

    foreach ($entry in $failPatterns) {
        if ([regex]::IsMatch($text, $entry.Pattern)) {
            $failures.Add([ordered]@{
                File = $file.FullName
                Pattern = $entry.Name
            })
        }
    }

    foreach ($entry in $warnPatterns) {
        if ([regex]::IsMatch($text, $entry.Pattern)) {
            $warnings.Add([ordered]@{
                File = $file.FullName
                Pattern = $entry.Name
            })
        }
    }
}

if ($warnings.Count -gt 0) {
    Write-Warning "Potential public-boundary warnings:"
    $warnings | ConvertTo-Json -Depth 4 | Write-Host
}

if ($failures.Count -gt 0) {
    $failures | ConvertTo-Json -Depth 4 | Write-Host
    Write-Error "Public-boundary check failed."
    exit 1
}

Write-Host "Public-boundary check passed for $resolvedRoot"
