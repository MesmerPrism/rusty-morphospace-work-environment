param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Inspect", "Claim", "Resume", "BeginValidation", "RecordValidation", "Accept", "PreparePush", "Recover")]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [string]$UnitId = "",
    [string]$RepoMapPath = "",
    [string]$RevisionsPath = "",
    [ValidateSet("pass", "partial", "fail", "blocked")][string]$ValidationResult = "pass",
    [string]$ValidationReceipt = "",
    [ValidateSet("quick", "standard", "deep")][string]$ValidationTier = "standard",
    [string[]]$DeviceSerials = @(),
    [string]$Timestamp = "",
    [string]$OutPath = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "WorkUnitAutomation.psm1") -Force

$arguments = @{
    Action = $Action
    WorkspaceRoot = $WorkspaceRoot
    UnitId = $UnitId
    RepoMapPath = $RepoMapPath
    RevisionsPath = $RevisionsPath
    ValidationResult = $ValidationResult
    ValidationReceipt = $ValidationReceipt
    ValidationTier = $ValidationTier
    DeviceSerials = $DeviceSerials
    Timestamp = $Timestamp
    OutPath = $OutPath
    Execute = $Execute
}

Invoke-MorphospaceWorkUnitAutomation @arguments | ConvertTo-Json -Depth 32
