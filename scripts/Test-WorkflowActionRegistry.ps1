[CmdletBinding()]
param([switch]$SelfTest, [switch]$UpdateGenerated)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$schemaPath = Join-Path $repo 'schemas/work-unit-automation-receipt-v2.schema.json'
$schemaText = [IO.File]::ReadAllText($schemaPath)
$schema = $schemaText | ConvertFrom-Json -Depth 64 -DateKind String
$registry = Get-Content (Join-Path $repo 'manifests/affected-validation-registry.json') -Raw | ConvertFrom-Json -Depth 64
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-WorkUnitAutomation.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Automation entrypoint does not parse.' }
$parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Action' })[0]
$attribute = @($parameter.Attributes | Where-Object { $_.TypeName.Name -ceq 'ValidateSet' })[0]
$entryActions = @($attribute.PositionalArguments | ForEach-Object { $_.SafeGetValue() })

function Get-RegisteredPairs([object]$Document) {
    $actions = [Collections.Generic.List[string]]::new()
    $transitions = [Collections.Generic.List[string]]::new()
    foreach ($relation in @($Document.allOf[0].oneOf)) {
        $action = [string]$relation.properties.action.const
        if ([string]::IsNullOrWhiteSpace($action) -or $actions.Contains($action)) { throw 'Duplicate or absent registered action.' }
        $actions.Add($action)
        $owner = $relation.'x-workflow-owner'
        if ((@($owner.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'owner_test,producer') { throw 'Action owner metadata must bind producer and owner_test.' }
        foreach ($name in @('producer','owner_test')) {
            $path = [string]$owner.$name
            if ($path -cnotmatch '^scripts/(?:lib/)?[A-Za-z0-9-]+\.ps(?:m)?1$' -or -not (Test-Path -LiteralPath (Join-Path $repo $path) -PathType Leaf)) { throw "Invalid action owner path: $path" }
        }
        if ($entryActions -cnotcontains $action) { throw "Action '$action' is absent from the CLI." }
        if (@($registry.checks | Where-Object { $_.command_path -ceq $owner.owner_test }).Count -eq 0) { throw "Action '$action' owner test is not registered in affected validation." }
        $rule = $relation.properties.transition
        $values = @(if ($rule.PSObject.Properties['enum']) { $rule.enum } else { $rule.const })
        if (-not $values.Count) { throw "Action '$action' has no transition." }
        foreach ($value in $values) {
            if ([string]::IsNullOrWhiteSpace($value) -or $transitions.Contains($value)) { throw 'Duplicate or absent registered transition.' }
            $transitions.Add([string]$value)
        }
    }
    return [pscustomobject]@{ actions=$actions.ToArray(); transitions=$transitions.ToArray() }
}

$pairs = Get-RegisteredPairs $schema
if ($UpdateGenerated) {
    # Keep published enum projections for existing consumers; relations own them.
    foreach ($row in @(@('action',$pairs.actions), @('transition',$pairs.transitions))) {
        $name = [string]$row[0]
        $json = ConvertTo-Json -InputObject @($row[1]) -Compress
        $pattern = '(?m)^    "' + $name + '":\{"enum":\[[^\]]*\]\}'
        if ([regex]::Matches($schemaText, $pattern).Count -ne 1) { throw "Expected one generated '$name' enum." }
        $schemaText = [regex]::Replace($schemaText, $pattern, ('    "' + $name + '":{"enum":' + $json + '}'))
    }
    [IO.File]::WriteAllText($schemaPath, $schemaText, [Text.UTF8Encoding]::new($false))
    $schema = $schemaText | ConvertFrom-Json -Depth 64 -DateKind String
}
if ((@($schema.properties.action.enum) -join ',') -cne ($pairs.actions -join ',') -or
    (@($schema.properties.transition.enum) -join ',') -cne ($pairs.transitions -join ',')) {
    throw 'Generated action/transition enums drifted; review relations then run -UpdateGenerated.'
}
if ($SelfTest) {
    foreach ($damage in @('duplicate-action','duplicate-transition','missing-owner','unregistered-test')) {
        $copy = $schema | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -DateKind String
        switch ($damage) {
            'duplicate-action' { $copy.allOf[0].oneOf[1].properties.action.const=$copy.allOf[0].oneOf[0].properties.action.const }
            'duplicate-transition' { $copy.allOf[0].oneOf[1].properties.transition.const=$copy.allOf[0].oneOf[0].properties.transition.const }
            'missing-owner' { $copy.allOf[0].oneOf[0].'x-workflow-owner'.producer='scripts/absent-owner.psm1' }
            'unregistered-test' { $copy.allOf[0].oneOf[0].'x-workflow-owner'.owner_test='scripts/Invoke-WorkUnitAutomation.ps1' }
        }
        $rejected=$false
        try { Get-RegisteredPairs $copy | Out-Null } catch { $rejected=$true }
        if (-not $rejected) { throw "Action registry accepted $damage damage." }
    }
}
[pscustomobject]@{status='pass';registered_actions=$pairs.actions.Count;registered_transitions=$pairs.transitions.Count;generated_updated=[bool]$UpdateGenerated}
