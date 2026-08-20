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

function Get-Utf8Sha256 {
    param([string]$Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    try { return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

$fixture = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $fixture @("schema", "purpose", "provider_corpus", "native_schema_ids", "launch_envelope", "runtime_observation_boundary", "consumer_wrapper_invariants", "required_case_ids") "consumer fixture"
Assert-ExactProperties $fixture.provider_corpus @("schema", "sha256", "current_main_commit", "provider_contract_merge_commit", "provider_contract_tree", "candidate_equal_commit") "consumer fixture accepted provider evidence"
Assert-True ([string]$fixture.schema -ceq "rusty.morphospace.quest_file_manager_consumer_fixture.v1") "Consumer fixture schema drifted."
Assert-True ([string]$fixture.provider_corpus.current_main_commit -ceq "a71206a707d2d68046101ec611fb4b3f8120104e" -and [string]$fixture.provider_corpus.provider_contract_merge_commit -ceq "3d84835ea213a75bbbfc781e6a1a4409b599bc28" -and [string]$fixture.provider_corpus.provider_contract_tree -ceq "5f8d9cb989afe6be59f7ec2c3515728efd21e9bf" -and [string]$fixture.provider_corpus.candidate_equal_commit -ceq "2bfdb5d57be3cabef7307e5b9865e98a5a409722") "Consumer fixture is not bound to accepted QFM source and provider-contract evidence."
Assert-True (@($fixture.native_schema_ids).Count -eq 4) "Native schema inventory changed."
Assert-True ((@($fixture.native_schema_ids) -join "|") -ceq "questionable.file_manager.inspected_deployment.v3|questionable.file_manager.apk_launch_result.v1|questionable.file_manager.launcher_export_proof.v2|questionable.file_manager.app_runtime_observation.v2") "Native schema identifiers changed."
Assert-True ((@($fixture.runtime_observation_boundary.does_not_prove) -join "|") -ceq "openxr_readiness|app_effect|wearer_visibility") "Runtime observation was upgraded into an XR or effect claim."
Assert-True ([bool]$fixture.consumer_wrapper_invariants.exactly_one_terminal_json_document -and [bool]$fixture.consumer_wrapper_invariants.all_outcomes_publish_atomically -and [bool]$fixture.consumer_wrapper_invariants.raw_streams_must_be_retained_and_digested) "Consumer terminal/evidence invariants weakened."

if (-not $ProviderCorpusPath) {
    Write-Host "Quest File Manager consumer fixture passed (owner corpus synchronization requires -ProviderCorpusPath)."
    exit 0
}

$providerPath = (Resolve-Path -LiteralPath $ProviderCorpusPath).Path
Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $providerPath).Hash.ToLowerInvariant() -ceq [string]$fixture.provider_corpus.sha256) "Owner corpus bytes differ from the accepted advertised corpus."
$provider = Get-Content -Raw -LiteralPath $providerPath | ConvertFrom-Json -Depth 64
Assert-ExactProperties $provider @("schema", "purpose", "native_schema_ids", "native_launch_envelope_invariant", "runtime_observation_v2", "consumer_terminal_contract", "cases") "owner corpus"
Assert-True ([string]$provider.schema -ceq [string]$fixture.provider_corpus.schema) "Owner corpus schema changed."
Assert-True ((@($provider.native_schema_ids) -join "|") -ceq (@($fixture.native_schema_ids) -join "|")) "Owner native schema inventory changed."
Assert-True ((@($provider.runtime_observation_v2.proves) -join "|") -ceq (@($fixture.runtime_observation_boundary.proves) -join "|")) "Runtime observation proof boundary changed."
Assert-True ((@($provider.runtime_observation_v2.does_not_prove) -join "|") -ceq (@($fixture.runtime_observation_boundary.does_not_prove) -join "|")) "Runtime observation no-effect boundary changed."
Assert-True ((@($provider.cases | ForEach-Object { [string]$_.id }) -join "|") -ceq (@($fixture.required_case_ids) -join "|")) "Owner corpus case inventory changed."

foreach ($case in @($provider.cases)) {
    Assert-ExactProperties $case @("id", "raw_streams", "native_launch_envelope", "expected") "owner case $($case.id)"
    Assert-True ((Get-Utf8Sha256 ([string]$case.raw_streams.stdout_utf8)) -ceq [string]$case.raw_streams.stdout_sha256) "Case $($case.id) stdout bytes do not match its digest."
    Assert-True ((Get-Utf8Sha256 ([string]$case.raw_streams.stderr_utf8)) -ceq [string]$case.raw_streams.stderr_sha256) "Case $($case.id) stderr bytes do not match its digest."
    Assert-True ([int]$case.expected.consumer_terminal_json_documents -eq 1 -and [string]$case.expected.final_file_publication -ceq "atomic") "Case $($case.id) weakens consumer terminal publication."
    if ($null -ne $case.native_launch_envelope) {
        $launch = $case.native_launch_envelope
        Assert-ExactProperties $launch @("schema", "succeeded", "mutation", "result", "failure") "native launch envelope $($case.id)"
        Assert-True ([string]$launch.schema -ceq [string]$fixture.launch_envelope.schema) "Case $($case.id) launch schema drifted."
        if ([bool]$launch.succeeded) {
            Assert-True ($null -ne $launch.mutation -and $null -ne $launch.result -and $null -eq $launch.failure) "Success case $($case.id) violates native launch nullability."
        } else {
            Assert-True ($null -eq $launch.mutation -and $null -eq $launch.result -and $null -ne $launch.failure) "Failure case $($case.id) violates native launch nullability."
        }
    }
}

Write-Host "Quest File Manager consumer fixture and exact owner corpus synchronization passed."
