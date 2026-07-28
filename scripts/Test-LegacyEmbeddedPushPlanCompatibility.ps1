$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
function Assert-LegacyPlan([bool]$Value,[string]$Message){if(-not$Value){throw "Legacy embedded-plan compatibility self-test failed: $Message"}}
$root=Split-Path $PSScriptRoot -Parent
$schema=Join-Path $root 'schemas\legacy-embedded-push-bundle-plan-v1.schema.json'
$example=Join-Path $root 'templates\legacy-embedded-push-bundle-plan.example.json'
$raw=Get-Content -Raw -LiteralPath $example
Assert-LegacyPlan (Test-Json -Json $raw -SchemaFile $schema) 'real-shape application/adapter/planning plan with null interruption rejected'
$baseline=$raw|ConvertFrom-Json
foreach($case in @(
    @{name='invalid role';mutate={param($d)$d.repositories[0].role='product'}},
    @{name='unknown plan field';mutate={param($d)$d|Add-Member -NotePropertyName unknown_field -NotePropertyValue $true}},
    @{name='unknown repository field';mutate={param($d)$d.repositories[0]|Add-Member -NotePropertyName unknown_field -NotePropertyValue $true}},
    @{name='malformed non-null interruption';mutate={param($d)$d.publication_ordering_interruption=[pscustomobject]@{kind='planning-published-before-source';early_planning_checkpoint_preserved=$true;source_publication_claimed=$false}}},
    @{name='expanded non-null interruption';mutate={param($d)$d.publication_ordering_interruption=[pscustomobject]@{path='receipts/example.json';sha256=('a'*64);kind='planning-published-before-source';early_planning_checkpoint_preserved=$true;source_publication_claimed=$false;unknown=$true}}}
)){
    $damaged=$baseline|ConvertTo-Json -Depth 20|ConvertFrom-Json
    & $case.mutate $damaged
    Assert-LegacyPlan (-not(Test-Json -Json ($damaged|ConvertTo-Json -Depth 20) -SchemaFile $schema -ErrorAction SilentlyContinue)) "$($case.name) was accepted"
}
Write-Host 'Legacy embedded-plan compatibility self-test passed.'
