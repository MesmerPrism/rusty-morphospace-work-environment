[CmdletBinding()]
param([string]$OutPath="",[ValidateRange(0,1)][int]$Attempt=0,[switch]$SelfTest)
Set-StrictMode -Version 2.0; $ErrorActionPreference='Stop'
$tools=@('git','pwsh','rg') | ForEach-Object { [pscustomobject][ordered]@{name=$_;available=($null -ne (Get-Command $_ -ErrorAction SilentlyContinue))} }
$result=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_infrastructure.v1';attempt=$Attempt;classification=$(if(@($tools|Where-Object{-not $_.available}).Count){'pending-infra'}else{'ready'});tools=@($tools);claims=[pscustomobject][ordered]@{acceptance_authority=$false;publication_authority=$false}}
$json=$result|ConvertTo-Json -Depth 16 -Compress
$schema=Join-Path $PSScriptRoot '..\schemas\affected-validation-infrastructure-v1.schema.json';if(-not(Test-Json -Json $json -SchemaFile $schema -ErrorAction Stop)){throw 'Infrastructure result fails its closed schema.'}
if($SelfTest){if($result.classification-cne'ready'){throw 'Local infrastructure self-test requires all bounded tools.'};Write-Host 'Affected-validation infrastructure self-test passed.';return}
if([string]::IsNullOrWhiteSpace($OutPath)){throw 'Infrastructure classification requires an exact output path.'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutPath),$json+[Environment]::NewLine,[Text.UTF8Encoding]::new($false));$result
