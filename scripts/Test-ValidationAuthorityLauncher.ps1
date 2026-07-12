$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceValidationAuthority.psm1') -Force

function Assert-Launcher { param([bool]$Condition,[string]$Message) if(-not $Condition){throw "Authority-launcher self-test failed: $Message"} }
function Assert-Rejected { param([scriptblock]$Action,[string]$Message) $rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Launcher $rejected $Message }

$temp=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-authority-launcher-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    $validator=Join-Path $temp 'fixture-validator.ps1'
    $body=@'
param([string]$WorkspaceRoot,[string]$QuestRoot,[string]$RoadmapPath,[string]$UnitId,[string]$OutPath)
[IO.File]::WriteAllText($OutPath,(@{workspace=$WorkspaceRoot;quest=$QuestRoot;roadmap=$RoadmapPath;unit=$UnitId}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
Write-Output 'fixture-validator-ran'
'@
    [IO.File]::WriteAllText($validator,$body,[Text.UTF8Encoding]::new($false))
    $owner=Join-Path $temp 'owner.json';$stdout=Join-Path $temp 'stdout.txt';$stderr=Join-Path $temp 'stderr.txt'
    $run=Invoke-MorphospacePinnedValidator -ValidatorPath $validator -Workspace 'workspace-marker' -Quest 'quest-marker' -Roadmap 'roadmap-marker' -Unit 'unit-marker' -OwnerOut $owner -StdoutPath $stdout -StderrPath $stderr -TimeoutSeconds 15
    $written=Get-Content -LiteralPath $owner -Raw|ConvertFrom-Json
    Assert-Launcher ($run.exit_code-eq0-and$run.stdout-match'fixture-validator-ran') 'child validator did not execute through the pinned launcher'
    Assert-Launcher ([string]$written.workspace-eq'workspace-marker'-and[string]$written.quest-eq'quest-marker'-and[string]$written.roadmap-eq'roadmap-marker'-and[string]$written.unit-eq'unit-marker') 'launcher arguments drifted'
    Assert-Rejected {Invoke-MorphospacePinnedValidator -ValidatorPath $validator -Workspace 'workspace-marker' -Quest 'quest-marker' -Roadmap 'roadmap-marker' -Unit 'unit-marker' -OwnerOut $owner -StdoutPath $stdout -StderrPath $stderr -TimeoutSeconds 15|Out-Null} 'preexisting output did not reject'
    Write-Host 'Authority-launcher self-test passed.'
} finally { if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)} }
