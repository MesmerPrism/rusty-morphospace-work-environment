$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceOwnership.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceAuthorityReadiness.psm1') -Force

function Assert-Readiness {param([bool]$Condition,[string]$Message)if(-not$Condition){throw "Authority-readiness self-test failed: $Message"}}
function Assert-Rejected {param([scriptblock]$Action,[string]$Message)$rejected=$false;try{&$Action}catch{$rejected=$true};Assert-Readiness $rejected $Message}
function Write-TestText {param([string]$Path,[string]$Text)$parent=[IO.Path]::GetDirectoryName($Path);if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Get-TestSha {param([string]$Text)$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-readiness-test-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null

    $hostProbe=Invoke-MorphospaceAuthorityHostProbe -RequiredCommands @('git.exe')
    Test-MorphospaceAuthorityHostCapabilitiesV1 $hostProbe @('git.exe')|Out-Null
    $missing=Invoke-MorphospaceAuthorityHostProbe -RequiredCommands @('morphospace-command-that-does-not-exist.exe')
    Assert-Readiness ([string]$missing.result-eq'fail') 'missing declared host command passed'

    $repo=Join-Path $temp 'owner';$runner=Join-Path $repo 'scripts\Invoke-MorphospaceValidationAuthority.ps1';Write-TestText $runner 'param()'
    $runnerSha=Get-MorphospaceReadinessSha256 $runner;$migration=[pscustomobject]@{authority_artifacts=@([pscustomobject]@{repo_id='work-environment';path='scripts/Invoke-MorphospaceValidationAuthority.ps1';sha256=$runnerSha;git_blob_oid=('a'*40)})}
    $map=@{'work-environment'=[pscustomobject]@{path=$repo}}
    $release=New-MorphospaceAuthorityRunnerReleaseV1 $migration $map $runner
    Test-MorphospaceAuthorityRunnerReleaseV1 $release $map|Out-Null

    $reference=[pscustomobject]@{role='validation-action';path='receipts/action.json';schema='rusty.morphospace.workflow.validation_action.v2';sha256=('b'*64)}
    $validator=[pscustomobject]@{validator_id='owner-test';owner_repo_id='work-environment';sha256=('c'*64);input_closure=@([pscustomobject]@{repo_id='work-environment';kind='git-tree';paths=@('scripts/')});history_blobs=@();timeout_seconds=30;max_output_bytes=4096;mutation_policy='temp-output-only';device_policy='forbidden'}
    $capsule=New-MorphospaceAuthorityInputCapsuleV1 -ProjectId 'readiness-test' -UnitId 'unit-test' -AttemptId 'attempt-test' -References @($reference) -Validator $validator -RunnerRelease $release
    Test-MorphospaceAuthorityInputCapsuleV1 $capsule|Out-Null
    $damaged=($capsule|ConvertTo-Json -Depth 30|ConvertFrom-Json);$damaged.content.attempt_id='attempt-damaged'
    Assert-Rejected {Test-MorphospaceAuthorityInputCapsuleV1 $damaged|Out-Null} 'capsule content drift was accepted'

    $ownerModule=Get-Module MorphospaceOwnership;$cacheResult=&$ownerModule {
        param($capsuleSha,$materializedSha)
        $parent=Join-Path ([IO.Path]::GetTempPath()) 'rusty-morphospace-cleanrooms';if(-not[IO.Directory]::Exists($parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}
        $source=Join-Path $parent ('readiness-fixture-'+[guid]::NewGuid().ToString('N'));$repoRoot=Join-Path $source 'fixture-repo';[IO.Directory]::CreateDirectory($repoRoot)|Out-Null;[IO.File]::WriteAllText((Join-Path $repoRoot 'input.txt'),'sealed',[Text.UTF8Encoding]::new($false))
        $guard=[guid]::NewGuid().ToString('N');$script:CleanRoomGuards[$source]=$guard;$repositories=@{'fixture-repo'=$repoRoot};$closure=@{'fixture-repo'=[string[]]@('input.txt')};$modes=@{'fixture-repo'=@{}}
        $clean=[pscustomobject]@{root=$source;parent=$parent;guard=$guard;repositories=$repositories;closure=$closure;modes_by_repository=$modes;history_rows=@()};$clean|Add-Member fingerprint_sha256 (Get-MorphospaceCleanRoomFingerprint $clean)
        $saved=Save-MorphospaceContentAddressedCleanRoom $clean $capsuleSha $materializedSha;Close-MorphospaceContentAddressedCleanRoom $saved
        $opened=Open-MorphospaceContentAddressedCleanRoom $capsuleSha $materializedSha;$reused=[bool]$opened.reused;$same=((Get-MorphospaceCleanRoomFingerprint $opened)-ceq[string]$opened.fingerprint_sha256);$rootPath=[string]$opened.root;$manifest=[string]$opened.cache_manifest;Close-MorphospaceContentAddressedCleanRoom $opened
        [IO.File]::AppendAllText((Join-Path $rootPath 'fixture-repo\input.txt'),'damage',[Text.UTF8Encoding]::new($false));$rejected=$false;try{$null=Open-MorphospaceContentAddressedCleanRoom $capsuleSha $materializedSha}catch{$rejected=$true}
        if([IO.Directory]::Exists($rootPath)){Remove-MorphospaceNoFollowTree $rootPath};if([IO.File]::Exists($manifest)){[IO.File]::Delete($manifest)}

        $capsule2=('7'*64);$source2=Join-Path $parent ('readiness-fixture-'+[guid]::NewGuid().ToString('N'));$repoRoot2=Join-Path $source2 'fixture-repo';[IO.Directory]::CreateDirectory($repoRoot2)|Out-Null;[IO.File]::WriteAllText((Join-Path $repoRoot2 'input.txt'),'sealed',[Text.UTF8Encoding]::new($false))
        $guard2=[guid]::NewGuid().ToString('N');$script:CleanRoomGuards[$source2]=$guard2;$clean2=[pscustomobject]@{root=$source2;parent=$parent;guard=$guard2;repositories=@{'fixture-repo'=$repoRoot2};closure=@{'fixture-repo'=[string[]]@('input.txt')};modes_by_repository=@{'fixture-repo'=@{}};history_rows=@()};$clean2|Add-Member fingerprint_sha256 (Get-MorphospaceCleanRoomFingerprint $clean2)
        $saved2=Save-MorphospaceContentAddressedCleanRoom $clean2 $capsule2 $capsule2;$root2=[string]$saved2.root;$manifest2=[string]$saved2.cache_manifest;Remove-MorphospaceContentAddressedCleanRoom $saved2 -RemoveManifest
        $removed=(-not [IO.Directory]::Exists($root2) -and -not [IO.File]::Exists($manifest2))

        $partial=('8'*64);$partialPaths=Get-MorphospaceCleanRoomCachePaths $partial;[IO.Directory]::CreateDirectory($partialPaths.root)|Out-Null;$partialRejected=$false;try{$null=Open-MorphospaceContentAddressedCleanRoom $partial $partial}catch{$partialRejected=$true};if([IO.Directory]::Exists($partialPaths.root)){Remove-MorphospaceNoFollowTree $partialPaths.root}
        return [pscustomobject]@{reused=$reused;same=$same;tamper_rejected=$rejected;removed=$removed;partial_rejected=$partialRejected}
    } ([string]$capsule.capsule_sha256) ([string]$capsule.capsule_sha256)
    Assert-Readiness ($cacheResult.reused-and$cacheResult.same-and$cacheResult.tamper_rejected-and$cacheResult.removed-and$cacheResult.partial_rejected) 'content-addressed clean-room reuse/tamper/cleanup gate failed'

    $actionRef=[pscustomobject]@{role='validation-action';path='receipts/action.json';schema='rusty.morphospace.workflow.validation_action.v2';sha256=('d'*64)};$capsuleRef=[pscustomobject]@{role='authority-input-capsule';path='receipts/capsule.json';schema='rusty.morphospace.workflow.authority_input_capsule.v1';sha256=('e'*64)};$hostRef=[pscustomobject]@{role='authority-host-capabilities';path='receipts/host.json';schema='rusty.morphospace.workflow.authority_host_capabilities.v1';sha256=('f'*64)};$releaseRef=[pscustomobject]@{role='authority-runner-release';path='receipts/release.json';schema='rusty.morphospace.workflow.authority_runner_release.v1';sha256=('1'*64)}
    $probe=[pscustomobject]@{validator_id='owner-test';status='pass';exit_code=0;owner_evidence_sha256=('4'*64);stdout_sha256=('5'*64);stderr_sha256=('6'*64)}
    $preflight=New-MorphospaceAuthorityPreflightV1 'readiness-test' 'unit-test' 'attempt-test' $actionRef $capsuleRef $hostRef $releaseRef $probe ('2'*64) $true
    Test-MorphospaceAuthorityPreflightV1 $preflight $actionRef $capsuleRef $hostRef $releaseRef 'readiness-test' 'unit-test' 'attempt-test'|Out-Null
    $stale=($preflight|ConvertTo-Json -Depth 20|ConvertFrom-Json);$stale.capsule.sha256=('3'*64)
    Assert-Rejected {Test-MorphospaceAuthorityPreflightV1 $stale $actionRef $capsuleRef $hostRef $releaseRef 'readiness-test' 'unit-test' 'attempt-test'|Out-Null} 'stale preflight capsule was accepted'
    $wrongIdentity=($preflight|ConvertTo-Json -Depth 20|ConvertFrom-Json);$wrongIdentity.unit_id='other-unit'
    Assert-Rejected {Test-MorphospaceAuthorityPreflightV1 $wrongIdentity $actionRef $capsuleRef $hostRef $releaseRef 'readiness-test' 'unit-test' 'attempt-test'|Out-Null} 'wrong preflight identity was accepted'
    $forgedProbe=($preflight|ConvertTo-Json -Depth 20|ConvertFrom-Json);$forgedProbe.owner_probe.owner_evidence_sha256='not-a-hash'
    Assert-Rejected {Test-MorphospaceAuthorityPreflightV1 $forgedProbe $actionRef $capsuleRef $hostRef $releaseRef 'readiness-test' 'unit-test' 'attempt-test'|Out-Null} 'malformed owner probe was accepted'

    $context=New-MorphospaceAuthorityReportContext 'readiness-test' 'unit-test' 'attempt-test' preflight
    try{throw 'nested readiness failure'}catch{$report=Write-MorphospaceAuthorityFailureReport $context 'sealed-owner-preflight' $_ ([DateTime]::UtcNow);Write-MorphospaceAuthorityStageResult $context 'sealed-owner-preflight' fail ([DateTime]::UtcNow) -FailureReportPath $context.failure_report|Out-Null}
    Assert-Readiness ([IO.File]::Exists($context.failure_report)-and[IO.File]::Exists($context.stage_result)) 'typed failure/stage reports were not retained'
    Assert-Rejected {Write-MorphospaceAuthorityStageResult $context 'sealed-owner-preflight' fail ([DateTime]::UtcNow)|Out-Null} 'stage result overwrite was accepted'

    $authoritySources=@('scripts/Invoke-MorphospaceValidationAuthority.ps1','scripts/WorkUnitAutomation.psm1','scripts/lib/MorphospaceOwnership.psm1','scripts/lib/MorphospaceValidationAuthority.psm1','scripts/lib/MorphospaceAuthorityReadiness.psm1')
    foreach($relative in $authoritySources){$path=Join-Path $root $relative;$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);if($errors){throw "Authority source does not parse: $relative"};$ambient=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and[string]$node.GetCommandName()-ceq'Get-FileHash'},$true));Assert-Readiness ($ambient.Count-eq0) "authority source uses ambient Get-FileHash: $relative"}
    $runnerText=Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-MorphospaceValidationAuthority.ps1') -Raw
    Assert-Readiness ($runnerText.Contains('function Invoke-MorphospaceIsolatedAuthoritySelfTest')-and@([regex]::Matches($runnerText,'Invoke-MorphospaceIsolatedAuthoritySelfTest -Migration \$migration')).Count-eq3) 'record self-tests are not isolated child processes'
    foreach($selfTestName in @('Test-ValidationAuthorityLauncher.ps1','Test-AuthorityRunnerHandoff.ps1','Test-TrustMigrationAuthority.ps1')){Assert-Readiness (-not$runnerText.Contains("& (Join-Path `$PSScriptRoot '$selfTestName')")) "record self-test still mutates the authority process module graph: $selfTestName"}

    Write-Host 'Authority record-readiness self-test passed.'
}finally{if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
