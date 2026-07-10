param(
    [string]$ConfigPath = "",
    [switch]$Strict,
    [switch]$SelfTest,
    [switch]$CheckQuestDevice
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$results = New-Object System.Collections.Generic.List[object]

function Add-CheckResult {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail,
        [bool]$Required = $false
    )

    $results.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Required = $Required
        Detail = $Detail
    })
}

function Test-CommandAvailable {
    param(
        [string]$Name,
        [bool]$Required = $false
    )

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        Add-CheckResult -Name $Name -Status "ok" -Required $Required -Detail $cmd.Source
    } else {
        $status = if ($Required) { "missing" } else { "optional-missing" }
        Add-CheckResult -Name $Name -Status $status -Required $Required -Detail "Command not found on PATH."
    }
}

function Test-PlaceholderValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return $true
    }

    $text = [string]$Value
    return ($text.Trim().Length -eq 0 -or $text.Trim().StartsWith("<"))
}

function Test-ConfiguredPath {
    param(
        [string]$Name,
        [object]$Value,
        [bool]$Required = $false
    )

    if (Test-PlaceholderValue $Value) {
        Add-CheckResult -Name $Name -Status "placeholder" -Required $Required -Detail "No local path configured."
        return
    }

    $path = [string]$Value
    if (Test-Path -LiteralPath $path) {
        Add-CheckResult -Name $Name -Status "ok" -Required $Required -Detail $path
    } else {
        $status = if ($Required) { "missing" } else { "optional-missing" }
        Add-CheckResult -Name $Name -Status $status -Required $Required -Detail $path
    }
}

function Invoke-JsonParseCheck {
    param([string]$Path)

    try {
        Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json | Out-Null
        Add-CheckResult -Name "json:$Path" -Status "ok" -Detail "Parsed JSON."
    } catch {
        Add-CheckResult -Name "json:$Path" -Status "missing" -Required $true -Detail $_.Exception.Message
    }
}

function Invoke-JsonLinesParseCheck {
    param([string]$Path)

    try {
        $lineNumber = 0
        foreach ($line in @(Get-Content -LiteralPath $Path)) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $line | ConvertFrom-Json | Out-Null
        }
        Add-CheckResult -Name "jsonl:$Path" -Status "ok" -Detail "Parsed JSON Lines."
    } catch {
        Add-CheckResult -Name "jsonl:$Path" -Status "missing" -Required $true -Detail "Line $lineNumber`: $($_.Exception.Message)"
    }
}

if ($SelfTest) {
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "manifests") -Filter "*.json" -File |
        ForEach-Object { Invoke-JsonParseCheck -Path $_.FullName }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "templates") -Filter "*.json" -File |
        ForEach-Object { Invoke-JsonParseCheck -Path $_.FullName }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "schemas") -Filter "*.json" -File |
        ForEach-Object { Invoke-JsonParseCheck -Path $_.FullName }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "templates") -Filter "*.jsonl" -File |
        ForEach-Object { Invoke-JsonLinesParseCheck -Path $_.FullName }

    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "scripts") -Filter "*.ps1" -File |
        ForEach-Object {
            try {
                [scriptblock]::Create((Get-Content -Raw -LiteralPath $_.FullName)) | Out-Null
                Add-CheckResult -Name "powershell:$($_.Name)" -Status "ok" -Detail "Parsed script."
            } catch {
                Add-CheckResult -Name "powershell:$($_.Name)" -Status "missing" -Required $true -Detail $_.Exception.Message
            }
        }

    try {
        & (Join-Path $RepoRoot "scripts\Test-WorkflowContracts.ps1") -RepoRoot $RepoRoot
        Add-CheckResult -Name "workflow:contracts" -Status "ok" -Detail "Validated lifecycle, schemas, and examples."
    } catch {
        Add-CheckResult -Name "workflow:contracts" -Status "missing" -Required $true -Detail $_.Exception.Message
    }

    try {
        & (Join-Path $RepoRoot "scripts\New-ProjectWorkspace.ps1") -SelfTest
        Add-CheckResult -Name "scaffold:project-workspace" -Status "ok" -Detail "Created, validated, and protected a temporary scaffold."
    } catch {
        Add-CheckResult -Name "scaffold:project-workspace" -Status "missing" -Required $true -Detail $_.Exception.Message
    }
}

Test-CommandAvailable -Name "git" -Required $true
Test-CommandAvailable -Name "rustup" -Required $true
Test-CommandAvailable -Name "cargo" -Required $true
Test-CommandAvailable -Name "python" -Required $true
Test-CommandAvailable -Name "rg" -Required $true

Test-CommandAvailable -Name "adb" -Required $false
Test-CommandAvailable -Name "java" -Required $false
Test-CommandAvailable -Name "javac" -Required $false
Test-CommandAvailable -Name "node" -Required $false
Test-CommandAvailable -Name "npm" -Required $false
Test-CommandAvailable -Name "npx" -Required $false
Test-CommandAvailable -Name "dotnet" -Required $false

if ($ConfigPath) {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
            Add-CheckResult -Name "config" -Status "ok" -Required $true -Detail $ConfigPath

            Test-ConfiguredPath -Name "workspace_root" -Value $config.workspace_root -Required $Strict.IsPresent
            Test-ConfiguredPath -Name "repos_root" -Value $config.repos_root -Required $Strict.IsPresent
            Test-ConfiguredPath -Name "artifacts_root" -Value $config.artifacts_root -Required $false
            Test-ConfiguredPath -Name "skills_root" -Value $config.skills_root -Required $false

            if ($config.android) {
                Test-ConfiguredPath -Name "android.sdk_root" -Value $config.android.sdk_root -Required $Strict.IsPresent
                Test-ConfiguredPath -Name "android.ndk_root" -Value $config.android.ndk_root -Required $false
                Test-ConfiguredPath -Name "android.jdk_root" -Value $config.android.jdk_root -Required $false
                Test-ConfiguredPath -Name "android.openxr_loader_quest" -Value $config.android.openxr_loader_quest -Required $false
            }
        } catch {
            Add-CheckResult -Name "config" -Status "missing" -Required $true -Detail $_.Exception.Message
        }
    } else {
        Add-CheckResult -Name "config" -Status "missing" -Required $Strict.IsPresent -Detail $ConfigPath
    }
}

if ($CheckQuestDevice) {
    $adb = Get-Command adb -ErrorAction SilentlyContinue
    if ($adb) {
        try {
            $devices = & $adb.Source devices -l
            Add-CheckResult -Name "adb.devices" -Status "ok" -Detail ($devices -join " | ")
        } catch {
            Add-CheckResult -Name "adb.devices" -Status "optional-missing" -Detail $_.Exception.Message
        }
    } else {
        Add-CheckResult -Name "adb.devices" -Status "optional-missing" -Detail "adb not found."
    }
}

$results | Sort-Object Name | Format-Table -AutoSize

$failedRequired = $results | Where-Object { $_.Required -and $_.Status -eq "missing" }
if ($Strict -and $failedRequired.Count -gt 0) {
    Write-Error "Required checks failed in strict mode."
    exit 1
}

if ($SelfTest) {
    $selfTestFailures = $results | Where-Object { $_.Name -match "^(json|jsonl|powershell|workflow|scaffold):" -and $_.Status -ne "ok" }
    if ($selfTestFailures.Count -gt 0) {
        Write-Error "Self-test failed."
        exit 1
    }
}

Write-Host "Environment check complete."
