param(
    [Parameter(Mandatory = $true)][string]$LockPath,
    [Parameter(Mandatory = $true)][string]$FeatureId,
    [Parameter(Mandatory = $true)][string]$RuntimeInput,
    [string]$ExpectedFingerprint = ""
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
$lock = Read-MorphospaceProtocolJson $LockPath
if ([string]$lock.schema -ne "rusty.morphospace.workflow.feature_lock.v2") { throw "Runtime activation requires feature_lock.v2." }

if (-not(Test-MorphospaceFeatureLockFingerprint $lock)) { throw "Feature lock fingerprint is stale or damaged." }
if ($ExpectedFingerprint -and [string]$lock.lock_fingerprint -ne $ExpectedFingerprint) { throw "Runtime lock fingerprint does not match the expected project lock." }
$feature = @($lock.features | Where-Object { [string]$_.feature_id -eq $FeatureId } | Select-Object -First 1)
if ($feature.Count -ne 1 -or $feature[0].selected -ne $true -or @($lock.selected_features) -notcontains $FeatureId) {
    throw "Feature '$FeatureId' is absent from the selected project lock."
}
if ([string]$feature[0].activation.rule -ne "selected-lock-and-runtime-input" -or @($feature[0].activation.runtime_inputs) -notcontains $RuntimeInput) {
    throw "Runtime input '$RuntimeInput' is not accepted for selected feature '$FeatureId'."
}
[pscustomobject][ordered]@{
    schema = "rusty.morphospace.workflow.feature_activation_decision.v1"
    project_id = [string]$lock.project_id
    lock_revision = [int]$lock.revision
    lock_fingerprint = [string]$lock.lock_fingerprint
    feature_id = $FeatureId
    runtime_input = $RuntimeInput
    accepted = $true
    effective_marker = [string]$feature[0].activation.effective_marker
}
