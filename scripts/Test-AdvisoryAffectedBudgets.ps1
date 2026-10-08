[CmdletBinding()]
param([string]$OutPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$owner=Split-Path $PSScriptRoot -Parent;$runner=Join-Path $PSScriptRoot 'Invoke-AffectedValidation.ps1'
$source=Get-Content $runner -Raw;$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);if($errors){throw 'Runner parse failed'}
$types=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]-and$n.GetCommandName()-eq'Add-Type'},$true));$definitions=@($types|ForEach-Object{$_.CommandElements}|Where-Object{$_-is[Management.Automation.Language.StringConstantExpressionAst]-and$_.Value.Contains('class W017BoundedChildCapture')});if($definitions.Count-ne1){throw 'Exact production child-capture definition missing'}
Add-Type -TypeDefinition $definitions[0].Value
$warningFn=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'Write-AffectedValidationBudgetWarning'},$true);if(!$warningFn){throw 'Production budget warning missing'};Invoke-Expression $warningFn.Extent.Text
$local=Join-Path $owner ('local/advisory-budget-control-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $local|Out-Null
$leaf=Join-Path $local 'leaf.ps1';[IO.File]::WriteAllText($leaf,"Start-Sleep -Milliseconds 2200`n[Console]::Out.Write('actual-complete')`n[Console]::Error.Write('actual-stderr')`n",[Text.UTF8Encoding]::new($false))
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
foreach($name in @('Get-AffectedValidationBytesHash','Get-AffectedValidationChildEnvironmentProjection')){$f=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq$name},$true);if(!$f){throw 'Production environment projection missing'};Invoke-Expression $f.Extent.Text}
$environment=Get-AffectedValidationChildEnvironmentProjection @{}
$exe=(Get-Process -Id $PID).Path;$args=@('-NoProfile','-NonInteractive','-File',$leaf)
$advisory=[W017BoundedChildCapture]::RunWithBudgetPolicy($exe,$local,$args,@($environment.names),@($environment.values),1,10485760,15000,$false)
if(!$advisory.Started-or$advisory.TimedOut-or!$advisory.EstimatedBudgetExceeded-or$advisory.ExitCode-ne0-or$advisory.OutputTruncated-or$advisory.PostKillDrainTimedOut-or!$advisory.ContainmentCleanupSucceeded-or!$advisory.SupervisorEvidenceCleanupSucceeded-or$advisory.Error){throw ('Advisory real-leaf completion failed: '+($advisory|ConvertTo-Json -Depth 5 -Compress))}
if([Text.Encoding]::UTF8.GetString($advisory.Stdout)-cne'actual-complete'-or[Text.Encoding]::UTF8.GetString($advisory.Stderr)-cne'actual-stderr'){throw 'Advisory raw EOF capture changed'}
$warnings=@();Write-AffectedValidationBudgetWarning -Check ([pscustomobject]@{check_id='real-advisory-leaf';budget_seconds=1}) -Child $advisory -WarningVariable warnings -WarningAction SilentlyContinue;if($warnings.Count-ne1){throw 'Default over-budget warning missing'}
$strict=[W017BoundedChildCapture]::RunWithBudgetPolicy($exe,$local,$args,@($environment.names),@($environment.values),1,10485760,15000,$true)
if(!$strict.Started-or!$strict.TimedOut-or!$strict.EstimatedBudgetExceeded-or!$strict.ChildTreeCleanupAttempted-or!$strict.ContainmentCleanupSucceeded-or!$strict.SupervisorEvidenceCleanupSucceeded){throw 'Explicit strict budget did not time out and clean owned child'}
if([Text.Encoding]::UTF8.GetString($strict.Stdout).Contains('actual-complete')){throw 'Canceled leaf claimed completion'}
$invoke=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'Invoke-AffectedValidationCheck'},$true).Extent.Text
if(!$invoke.Contains('RunWithBudgetPolicy')-or!$invoke.Contains('[bool]$StrictBudget')-or!$invoke.Contains('Assert-MorphospaceAffectedBatchedWorkingBytes')){throw 'Production command/source integrity route changed'}
$result=[ordered]@{passed=$true;real_leaf_outlasts_estimate=$true;default_warning_observed=$true;strict_timeout_and_owned_cleanup=$true;raw_stdout_stderr_complete=$true;production_source_integrity_predicates_retained=$true;dynamic_candidate_evidence_only=$true;acceptance_authority=$false;publication_authority=$false;device_used=$false}
if($OutPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutPath),($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))};$result|ConvertTo-Json
