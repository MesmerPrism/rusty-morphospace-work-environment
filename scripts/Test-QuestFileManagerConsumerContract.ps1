param(
    [string]$RepoRoot = "",
    [string]$ProviderCorpusPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$fixturePath = Join-Path $RepoRoot "fixtures\quest-file-manager\inspected-deployment-consumer.v1.json"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Quest File Manager consumer contract failed: $Message" }
}

function Assert-ExactProperties {
    param([object]$Value, [string[]]$Names, [string]$Location)
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    Assert-True (($actual -join "|") -ceq ($expected -join "|")) "$Location property set changed."
}

$fixture = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $fixture @("schema", "purpose", "provider_corpus", "native_schema_ids", "runtime_observation_boundary", "permission_observation_boundary", "consumer_wrapper_invariants", "required_case_ids") "consumer fixture"
Assert-ExactProperties $fixture.provider_corpus @("current_main_commit", "current_main_tree", "historical_candidate_evidence") "consumer fixture QFM evidence"
Assert-True ([string]$fixture.schema -ceq "rusty.morphospace.quest_file_manager_consumer_fixture.v3") "Consumer fixture schema drifted."
Assert-True ([string]$fixture.provider_corpus.current_main_commit -ceq "8b010fa25b5c5d8fbae8d20b4389d587ca7bdef7" -and [string]$fixture.provider_corpus.current_main_tree -ceq "3481395fdfc49e67d239cbce7bba8cae82fbf793") "Consumer fixture is not bound to the QFM runtime-v6 source."
$contracts = "questionable.file_manager.inspected_deployment.v5|questionable.file_manager.apk_preflight_result.v1|questionable.file_manager.apk_deploy_result.v1|questionable.file_manager.apk_diagnostic_result.v3|questionable.file_manager.apk_diagnostic_bundle.v3|questionable.file_manager.apk_stop_result.v1|questionable.file_manager.apk_permission_observation.v1|questionable.file_manager.adb_forward_inventory_result.v1|questionable.file_manager.apk_launch_result.v1|questionable.file_manager.launcher_export_proof.v2|questionable.file_manager.app_runtime_observation.v6|questionable.file_manager.android_global_focus_observation.v1"
Assert-True ((@($fixture.native_schema_ids) -join "|") -ceq $contracts) "Native schema identifiers changed."
Assert-True ([string]$fixture.runtime_observation_boundary.schema -ceq 'questionable.file_manager.app_runtime_observation.v6') "Consumer runtime boundary is not v6."
Assert-True ((@($fixture.runtime_observation_boundary.does_not_prove) -join "|") -ceq "openxr_readiness|app_effect|wearer_visibility|panel_paused_state|advancing_focused_or_submitted_frames|app_owned_handoff_marker") "Runtime observation was upgraded into a semantic claim."
Assert-True ((@($fixture.permission_observation_boundary.does_not_prove) -join "|") -ceq "permission_policy|permission_grantability|feature_use|app_readiness|openxr_readiness|wearer_visibility") "Permission observation was upgraded into a policy or semantic claim."
Assert-True ([bool]$fixture.consumer_wrapper_invariants.exactly_one_terminal_json_document -and [bool]$fixture.consumer_wrapper_invariants.all_outcomes_publish_atomically -and [bool]$fixture.consumer_wrapper_invariants.raw_streams_must_be_retained_and_digested -and [bool]$fixture.consumer_wrapper_invariants.unknown_or_unavailable_is_explicit -and [bool]$fixture.consumer_wrapper_invariants.android_facts_never_establish_readiness) "Consumer terminal/evidence invariants weakened."

# Exercise the real projection behind this declaration, including retained
# v3/v4/v5 decoding and the native v6 process/focus cases.
& (Join-Path $RepoRoot 'scripts/Test-QuestFileManagerRuntimeObservationAdapter.ps1') -RepoRoot $RepoRoot

if (-not $ProviderCorpusPath) {
    Write-Host "Quest File Manager runtime-v6 consumer fixture passed (owner corpus synchronization requires -ProviderCorpusPath)."
    return
}

$provider = Get-Content -Raw -LiteralPath (Resolve-Path -LiteralPath $ProviderCorpusPath).Path | ConvertFrom-Json -Depth 64
Assert-True ([string]$provider.schema -ceq "questionable.file_manager.inspected_deployment_provider_conformance.v1") "Owner corpus schema changed."
Assert-True ((@($provider.native_schema_ids) -join "|") -ceq "questionable.file_manager.inspected_deployment.v5|questionable.file_manager.apk_launch_result.v1|questionable.file_manager.launcher_export_proof.v2|questionable.file_manager.app_runtime_observation.v6") "Owner corpus runtime contract changed."
# The producer retains this historical property name; its schema is v6.
Assert-True ([string]$provider.runtime_observation_v5.schema -ceq [string]$fixture.runtime_observation_boundary.schema) "Owner corpus runtime boundary changed."
Assert-True ((@($provider.runtime_observation_v5.does_not_prove) -join "|") -ceq (@($fixture.runtime_observation_boundary.does_not_prove) -join "|")) "Owner corpus readiness boundary changed."
Write-Host "Quest File Manager runtime-v6 consumer fixture and owner corpus synchronization passed."
