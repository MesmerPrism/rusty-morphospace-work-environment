Microsoft.PowerShell.Core\Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Microsoft.PowerShell.Core\Import-Module ([IO.Path]::Combine($PSScriptRoot,'MorphospaceProtocolCommon.psm1')) -Force

function Get-MorphospaceReadinessSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not[IO.File]::Exists($Path)){throw "Readiness artifact does not exist: $Path"}
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
}

function Write-MorphospaceReadinessJsonNoOverwrite {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][object]$Value)
    if([IO.File]::Exists($Path)-or[IO.Directory]::Exists($Path)){throw "Refusing to overwrite readiness artifact: $Path"}
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path));if(-not[IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 80))
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

function Assert-MorphospaceReadinessId {
    param([Parameter(Mandatory=$true)][string]$Value,[Parameter(Mandatory=$true)][string]$Label)
    if($Value-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'){throw "$Label is invalid: $Value"}
}

function Assert-MorphospaceReadinessReference {
    param([Parameter(Mandatory=$true)][object]$Reference,[Parameter(Mandatory=$true)][string]$Label)
    Assert-MorphospaceExactPropertySet $Reference @('role','path','schema','sha256') @() $Label
    if([string]$Reference.role-notmatch'^[a-z0-9][a-z0-9-]{1,95}$'){throw "$Label role is invalid."}
    $path=ConvertTo-MorphospaceProtocolRelativePath ([string]$Reference.path)
    if([string]$Reference.path-cne$path-or[string]$Reference.schema-notmatch'^[a-z0-9][a-z0-9._-]{2,191}$'-or[string]$Reference.sha256-notmatch'^[0-9a-f]{64}$'){throw "$Label is malformed."}
    return [pscustomobject][ordered]@{role=[string]$Reference.role;path=$path;schema=[string]$Reference.schema;sha256=[string]$Reference.sha256}
}

function New-MorphospaceAuthorityRunnerReleaseV1 {
    param([Parameter(Mandatory=$true)][object]$Migration,[Parameter(Mandatory=$true)][hashtable]$RepositoryMap,[Parameter(Mandatory=$true)][string]$RunnerPath)
    $rows=[Collections.Generic.List[object]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in @($Migration.authority_artifacts|Sort-Object repo_id,path)){
        Assert-MorphospaceExactPropertySet $artifact @('repo_id','path','sha256','git_blob_oid') @() 'runner release source artifact'
        $repoId=[string]$artifact.repo_id;Assert-MorphospaceReadinessId $repoId 'Runner release repository id'
        $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$artifact.path);$key="$repoId/$relative"
        if([string]$artifact.path-cne$relative-or-not$seen.Add($key)-or[string]$artifact.sha256-notmatch'^[0-9a-f]{64}$'-or[string]$artifact.git_blob_oid-notmatch'^(?:[0-9a-f]{40}|[0-9a-f]{64})$'){throw "Runner release source artifact is malformed or repeated: $key"}
        if(-not$RepositoryMap.ContainsKey($repoId)){throw "Runner release repository is unavailable: $repoId"}
        $root=[IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path);$absolute=[IO.Path]::GetFullPath((Join-Path $root $relative));Assert-MorphospaceNoReparseAncestor $root $absolute
        if(-not[IO.File]::Exists($absolute)){throw "Runner release artifact is missing: $repoId/$([string]$artifact.path)"}
        $live=Get-MorphospaceReadinessSha256 $absolute
        if($live-cne[string]$artifact.sha256){throw "Runner release artifact drifted: $repoId/$([string]$artifact.path)"}
        $rows.Add([pscustomobject][ordered]@{repo_id=$repoId;path=$relative;sha256=$live;git_blob_oid=[string]$artifact.git_blob_oid})|Out-Null
    }
    $runner=[IO.Path]::GetFullPath($RunnerPath);$runnerRows=@($rows|Where-Object{[string]$_.repo_id-ceq'work-environment'-and[string]$_.path-ceq'scripts/Invoke-MorphospaceValidationAuthority.ps1'})
    if($runnerRows.Count-ne1-or(Get-MorphospaceReadinessSha256 $runner)-cne[string]$runnerRows[0].sha256){throw 'Runner release does not contain the exact authority runner.'}
    $content=[pscustomobject][ordered]@{artifacts=@($rows.ToArray());runner=[pscustomobject][ordered]@{repo_id='work-environment';path='scripts/Invoke-MorphospaceValidationAuthority.ps1';sha256=[string]$runnerRows[0].sha256}}
    return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.authority_runner_release.v1';content=$content;content_sha256=Get-MorphospaceCanonicalJsonSha256 $content;status='sealed'}
}

function Test-MorphospaceAuthorityRunnerReleaseV1 {
    param([Parameter(Mandatory=$true)][object]$Release,[Parameter(Mandatory=$true)][hashtable]$RepositoryMap)
    Assert-MorphospaceExactPropertySet $Release @('schema','content','content_sha256','status') @() 'authority runner release'
    Assert-MorphospaceExactPropertySet $Release.content @('artifacts','runner') @() 'authority runner release content'
    if([string]$Release.schema-cne'rusty.morphospace.workflow.authority_runner_release.v1'-or[string]$Release.status-cne'sealed'-or[string]$Release.content_sha256-notmatch'^[0-9a-f]{64}$'-or(Get-MorphospaceCanonicalJsonSha256 $Release.content)-cne[string]$Release.content_sha256){throw 'Authority runner release is malformed or drifted.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$runnerMatches=0
    foreach($artifact in @($Release.content.artifacts)){
        Assert-MorphospaceExactPropertySet $artifact @('repo_id','path','sha256','git_blob_oid') @() 'authority runner release artifact'
        $repoId=[string]$artifact.repo_id;Assert-MorphospaceReadinessId $repoId 'Runner release repository id';$relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$artifact.path);$key="$repoId/$relative"
        if([string]$artifact.path-cne$relative-or-not$seen.Add($key)-or[string]$artifact.sha256-notmatch'^[0-9a-f]{64}$'-or[string]$artifact.git_blob_oid-notmatch'^(?:[0-9a-f]{40}|[0-9a-f]{64})$'){throw "Runner release artifact is malformed or repeated: $key"}
        if(-not$RepositoryMap.ContainsKey($repoId)){throw "Runner release repository is unavailable: $repoId"};$root=[IO.Path]::GetFullPath([string]$RepositoryMap[$repoId].path);$absolute=[IO.Path]::GetFullPath((Join-Path $root $relative));Assert-MorphospaceNoReparseAncestor $root $absolute
        if(-not[IO.File]::Exists($absolute)-or(Get-MorphospaceReadinessSha256 $absolute)-cne[string]$artifact.sha256){throw "Runner release artifact drifted: $key"}
        if($key-ceq'work-environment/scripts/Invoke-MorphospaceValidationAuthority.ps1'){$runnerMatches++}
    }
    Assert-MorphospaceExactPropertySet $Release.content.runner @('repo_id','path','sha256') @() 'authority runner release pointer'
    if($runnerMatches-ne1-or[string]$Release.content.runner.repo_id-cne'work-environment'-or[string]$Release.content.runner.path-cne'scripts/Invoke-MorphospaceValidationAuthority.ps1'-or-not$seen.Contains('work-environment/scripts/Invoke-MorphospaceValidationAuthority.ps1')){throw 'Authority runner release pointer is not the unique runner artifact.'}
    $runnerArtifact=@($Release.content.artifacts|Where-Object{[string]$_.repo_id-ceq'work-environment'-and[string]$_.path-ceq'scripts/Invoke-MorphospaceValidationAuthority.ps1'})
    if([string]$Release.content.runner.sha256-cne[string]$runnerArtifact[0].sha256){throw 'Authority runner release pointer digest drifted.'}
    return $Release
}

function Invoke-MorphospaceAuthorityHostProbe {
    param([string[]]$RequiredCommands=@('git.exe'),[string]$HostPath='')
    foreach($command in $RequiredCommands){if([string]$command-notmatch'^[A-Za-z0-9_.-]{2,96}$'){throw "Host-probe command name is invalid: $command"}}
    if(-not$HostPath){$HostPath=(Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source}
    $host=[IO.Path]::GetFullPath($HostPath);if(-not[IO.File]::Exists($host)){throw "Pinned child host is missing: $host"}
    $commandJson=@($RequiredCommands)|ConvertTo-Json -Compress
    $body=@"
`$ErrorActionPreference='Stop'
`$required=@($commandJson)
`$rows=@()
foreach(`$name in `$required){`$resolved=Get-Command `$name -CommandType Application,Cmdlet,Function -ErrorAction SilentlyContinue;`$rows+=[pscustomobject]@{name=`$name;available=(`$null-ne`$resolved);source=if(`$resolved){[string]`$resolved.Source}else{`$null}}}
`$shaOk=`$false
try{`$sha=[Security.Cryptography.SHA256]::Create();try{`$null=`$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('morphospace-authority-host-probe'));`$shaOk=`$true}finally{`$sha.Dispose()}}catch{}
`$result=if(`$shaOk-and@(`$rows|Where-Object{-not`$_.available}).Count-eq0){'pass'}else{'fail'}
[pscustomobject][ordered]@{powershell_version=`$PSVersionTable.PSVersion.ToString();edition=[string]`$PSVersionTable.PSEdition;language_mode=[string]`$ExecutionContext.SessionState.LanguageMode;dotnet_sha256=`$shaOk;commands=`$rows;result=`$result}|ConvertTo-Json -Depth 8 -Compress
if(`$result-ne'pass'){exit 17}
"@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body));$temp=Join-Path ([IO.Path]::GetTempPath()) ('morphospace-host-probe-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($temp)|Out-Null;$stdout=Join-Path $temp 'stdout.json';$stderr=Join-Path $temp 'stderr.txt'
    try{$process=Start-Process -FilePath $host -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr;try{if(-not$process.WaitForExit(30000)){try{$process.Kill()}catch{};throw 'Pinned child-host probe timed out.'};$exit=[int]$process.ExitCode}finally{$process.Dispose()};$out=if([IO.File]::Exists($stdout)){[IO.File]::ReadAllText($stdout,[Text.UTF8Encoding]::new($false)).Trim()}else{''};$err=if([IO.File]::Exists($stderr)){[IO.File]::ReadAllText($stderr,[Text.UTF8Encoding]::new($false))}else{''};if(-not$out){throw "Pinned child-host probe produced no result: $err"};$child=$out|ConvertFrom-Json;$content=[pscustomobject][ordered]@{host_sha256=Get-MorphospaceReadinessSha256 $host;powershell_version=[string]$child.powershell_version;edition=[string]$child.edition;language_mode=[string]$child.language_mode;dotnet_sha256=[bool]$child.dotnet_sha256;commands=@($child.commands);exit_code=$exit};$result=if($exit-eq0-and[string]$child.result-eq'pass'){'pass'}else{'fail'};return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.authority_host_capabilities.v1';captured_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');content=$content;content_sha256=Get-MorphospaceCanonicalJsonSha256 $content;result=$result}}finally{if([IO.Directory]::Exists($temp)){[IO.Directory]::Delete($temp,$true)}}
}

function Test-MorphospaceAuthorityHostCapabilitiesV1 {
    param([Parameter(Mandatory=$true)][object]$Capabilities,[string[]]$RequiredCommands=@('git.exe'))
    Assert-MorphospaceExactPropertySet $Capabilities @('schema','captured_at','content','content_sha256','result') @() 'authority host capabilities'
    Assert-MorphospaceExactPropertySet $Capabilities.content @('host_sha256','powershell_version','edition','language_mode','dotnet_sha256','commands','exit_code') @() 'authority host capability content'
    if([string]$Capabilities.schema-cne'rusty.morphospace.workflow.authority_host_capabilities.v1'-or[string]$Capabilities.result-cne'pass'-or-not(Test-MorphospaceStrictUtcTimestamp ([string]$Capabilities.captured_at))-or[string]$Capabilities.content.host_sha256-notmatch'^[0-9a-f]{64}$'-or(Get-MorphospaceCanonicalJsonSha256 $Capabilities.content)-cne[string]$Capabilities.content_sha256-or-not[bool]$Capabilities.content.dotnet_sha256-or[int]$Capabilities.content.exit_code-ne0){throw 'Authority child-host capability probe did not pass.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($command in @($Capabilities.content.commands)){Assert-MorphospaceExactPropertySet $command @('name','available','source') @() 'authority host command';if([string]$command.name-notmatch'^[A-Za-z0-9_.-]{2,96}$'-or-not$seen.Add([string]$command.name)-or([bool]$command.available-and-not[string]$command.source)){throw 'Authority child-host command evidence is malformed or repeated.'}}
    foreach($required in $RequiredCommands){$rows=@($Capabilities.content.commands|Where-Object{[string]$_.name-ceq$required-and[bool]$_.available});if($rows.Count-ne1){throw "Authority child host lacks declared command: $required"}}
    return $Capabilities
}

function New-MorphospaceAuthorityInputCapsuleV1 {
    param([Parameter(Mandatory=$true)][string]$ProjectId,[Parameter(Mandatory=$true)][string]$UnitId,[Parameter(Mandatory=$true)][string]$AttemptId,[Parameter(Mandatory=$true)][object[]]$References,[Parameter(Mandatory=$true)][object]$Validator,[Parameter(Mandatory=$true)][object]$RunnerRelease)
    Assert-MorphospaceReadinessId $ProjectId 'Capsule project id';Assert-MorphospaceReadinessId $UnitId 'Capsule unit id';Assert-MorphospaceReadinessId $AttemptId 'Capsule attempt id'
    if(@($References).Count-eq0){throw 'Authority input capsule requires references.'};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $referenceRows=@($References|ForEach-Object{$row=Assert-MorphospaceReadinessReference $_ 'capsule reference';if(-not$seen.Add("$([string]$row.role)/$([string]$row.path)")){throw 'Authority input capsule repeats a reference.'};$row}|Sort-Object role,path)
    Assert-MorphospaceReadinessId ([string]$Validator.validator_id) 'Capsule validator id';Assert-MorphospaceReadinessId ([string]$Validator.owner_repo_id) 'Capsule validator owner repo id'
    if([string]$Validator.sha256-notmatch'^[0-9a-f]{64}$'-or[int]$Validator.timeout_seconds-lt1-or[int]$Validator.max_output_bytes-lt1-or[string]$RunnerRelease.content_sha256-notmatch'^[0-9a-f]{64}$'){throw 'Authority input capsule validator or runner release is malformed.'}
    $validatorContent=[pscustomobject][ordered]@{validator_id=[string]$Validator.validator_id;owner_repo_id=[string]$Validator.owner_repo_id;sha256=[string]$Validator.sha256;registry_entry_sha256=Get-MorphospaceCanonicalJsonSha256 $Validator;input_closure_sha256=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{closure=@($Validator.input_closure)});history_sha256=Get-MorphospaceCanonicalJsonSha256 ([pscustomobject]@{history=@($Validator.history_blobs)});timeout_seconds=[int]$Validator.timeout_seconds;max_output_bytes=[int]$Validator.max_output_bytes;mutation_policy=[string]$Validator.mutation_policy;device_policy=[string]$Validator.device_policy}
    $content=[pscustomobject][ordered]@{project_id=$ProjectId;unit_id=$UnitId;attempt_id=$AttemptId;references=$referenceRows;validator=$validatorContent;runner_release_sha256=[string]$RunnerRelease.content_sha256;materializer='MorphospaceOwnership/New-MorphospaceCleanRoom'}
    return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.authority_input_capsule.v1';content=$content;capsule_sha256=Get-MorphospaceCanonicalJsonSha256 $content;status='sealed'}
}

function Test-MorphospaceAuthorityInputCapsuleV1 {
    param([Parameter(Mandatory=$true)][object]$Capsule)
    Assert-MorphospaceExactPropertySet $Capsule @('schema','content','capsule_sha256','status') @() 'authority input capsule';Assert-MorphospaceExactPropertySet $Capsule.content @('project_id','unit_id','attempt_id','references','validator','runner_release_sha256','materializer') @() 'authority input capsule content'
    if([string]$Capsule.schema-cne'rusty.morphospace.workflow.authority_input_capsule.v1'-or[string]$Capsule.status-cne'sealed'-or[string]$Capsule.capsule_sha256-notmatch'^[0-9a-f]{64}$'-or(Get-MorphospaceCanonicalJsonSha256 $Capsule.content)-cne[string]$Capsule.capsule_sha256){throw 'Authority input capsule is malformed or drifted.'}
    Assert-MorphospaceReadinessId ([string]$Capsule.content.project_id) 'Capsule project id';Assert-MorphospaceReadinessId ([string]$Capsule.content.unit_id) 'Capsule unit id';Assert-MorphospaceReadinessId ([string]$Capsule.content.attempt_id) 'Capsule attempt id'
    if([string]$Capsule.content.runner_release_sha256-notmatch'^[0-9a-f]{64}$'-or[string]$Capsule.content.materializer-cne'MorphospaceOwnership/New-MorphospaceCleanRoom'){throw 'Authority input capsule runner or materializer is invalid.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$prior='';foreach($reference in @($Capsule.content.references)){$row=Assert-MorphospaceReadinessReference $reference 'capsule reference';$key="$([string]$row.role)/$([string]$row.path)";if(-not$seen.Add($key)-or($prior-and[StringComparer]::Ordinal.Compare($prior,$key)-gt0)){throw 'Authority input capsule references are repeated or unsorted.'};$prior=$key}
    Assert-MorphospaceExactPropertySet $Capsule.content.validator @('validator_id','owner_repo_id','sha256','registry_entry_sha256','input_closure_sha256','history_sha256','timeout_seconds','max_output_bytes','mutation_policy','device_policy') @() 'authority capsule validator'
    Assert-MorphospaceReadinessId ([string]$Capsule.content.validator.validator_id) 'Capsule validator id';Assert-MorphospaceReadinessId ([string]$Capsule.content.validator.owner_repo_id) 'Capsule validator owner repo id'
    foreach($field in @('sha256','registry_entry_sha256','input_closure_sha256','history_sha256')){if([string]$Capsule.content.validator.$field-notmatch'^[0-9a-f]{64}$'){throw "Authority capsule validator $field is invalid."}}
    if([int]$Capsule.content.validator.timeout_seconds-lt1-or[int]$Capsule.content.validator.max_output_bytes-lt1-or-not[string]$Capsule.content.validator.mutation_policy-or-not[string]$Capsule.content.validator.device_policy){throw 'Authority capsule validator policy is invalid.'}
    return $Capsule
}

function New-MorphospaceAuthorityPreflightV1 {
    param([Parameter(Mandatory=$true)][string]$ProjectId,[Parameter(Mandatory=$true)][string]$UnitId,[Parameter(Mandatory=$true)][string]$AttemptId,[Parameter(Mandatory=$true)][object]$ActionReference,[Parameter(Mandatory=$true)][object]$CapsuleReference,[Parameter(Mandatory=$true)][object]$HostReference,[Parameter(Mandatory=$true)][object]$RunnerReleaseReference,[Parameter(Mandatory=$true)][object]$OwnerProbe,[Parameter(Mandatory=$true)][string]$CleanroomFingerprint,[Parameter(Mandatory=$true)][bool]$CapsuleReused)
    return [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.authority_preflight_result.v1';preflight_id="$UnitId-$AttemptId-preflight";completed_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');project_id=$ProjectId;unit_id=$UnitId;attempt_id=$AttemptId;action=$ActionReference;capsule=$CapsuleReference;host_capabilities=$HostReference;runner_release=$RunnerReleaseReference;cleanroom_fingerprint_sha256=$CleanroomFingerprint;capsule_reused=$CapsuleReused;owner_probe=$OwnerProbe;status='ready-for-record';does_not_prove=@('Does not constitute owner validation evidence, validation execution, a validation receipt, acceptance, or an external-operation receipt.')}
}

function Test-MorphospaceAuthorityPreflightV1 {
    param([Parameter(Mandatory=$true)][object]$Preflight,[Parameter(Mandatory=$true)][object]$ActionReference,[Parameter(Mandatory=$true)][object]$CapsuleReference,[Parameter(Mandatory=$true)][object]$HostReference,[Parameter(Mandatory=$true)][object]$RunnerReleaseReference,[Parameter(Mandatory=$true)][string]$ExpectedProjectId,[Parameter(Mandatory=$true)][string]$ExpectedUnitId,[Parameter(Mandatory=$true)][string]$ExpectedAttemptId)
    Assert-MorphospaceExactPropertySet $Preflight @('schema','preflight_id','completed_at','project_id','unit_id','attempt_id','action','capsule','host_capabilities','runner_release','cleanroom_fingerprint_sha256','capsule_reused','owner_probe','status','does_not_prove') @() 'authority preflight'
    Assert-MorphospaceReadinessId $ExpectedProjectId 'Expected preflight project id';Assert-MorphospaceReadinessId $ExpectedUnitId 'Expected preflight unit id';Assert-MorphospaceReadinessId $ExpectedAttemptId 'Expected preflight attempt id'
    if([string]$Preflight.schema-cne'rusty.morphospace.workflow.authority_preflight_result.v1'-or[string]$Preflight.status-cne'ready-for-record'-or[string]$Preflight.project_id-cne$ExpectedProjectId-or[string]$Preflight.unit_id-cne$ExpectedUnitId-or[string]$Preflight.attempt_id-cne$ExpectedAttemptId-or[string]$Preflight.preflight_id-cne"$ExpectedUnitId-$ExpectedAttemptId-preflight"-or-not(Test-MorphospaceStrictUtcTimestamp ([string]$Preflight.completed_at))-or[string]$Preflight.cleanroom_fingerprint_sha256-notmatch'^[0-9a-f]{64}$'-or@($Preflight.does_not_prove).Count-eq0){throw 'Authority preflight is not ready for record.'}
    Assert-MorphospaceExactPropertySet $Preflight.owner_probe @('validator_id','status','exit_code','owner_evidence_sha256','stdout_sha256','stderr_sha256') @() 'authority preflight owner probe';Assert-MorphospaceReadinessId ([string]$Preflight.owner_probe.validator_id) 'Preflight validator id'
    if([string]$Preflight.owner_probe.status-cne'pass'-or[int]$Preflight.owner_probe.exit_code-ne0){throw 'Authority preflight owner probe did not pass.'};foreach($field in @('owner_evidence_sha256','stdout_sha256','stderr_sha256')){if([string]$Preflight.owner_probe.$field-notmatch'^[0-9a-f]{64}$'){throw "Authority preflight owner probe $field is invalid."}}
    foreach($pair in @(@($Preflight.action,$ActionReference),@($Preflight.capsule,$CapsuleReference),@($Preflight.host_capabilities,$HostReference),@($Preflight.runner_release,$RunnerReleaseReference))){if([string]$pair[0].path-cne[string]$pair[1].path-or[string]$pair[0].sha256-cne[string]$pair[1].sha256-or[string]$pair[0].schema-cne[string]$pair[1].schema){throw 'Authority preflight reference drifted from current readiness inputs.'}}
    return $Preflight
}

function New-MorphospaceAuthorityReportContext {
    param([Parameter(Mandatory=$true)][string]$ProjectId,[Parameter(Mandatory=$true)][string]$UnitId,[Parameter(Mandatory=$true)][string]$AttemptId,[Parameter(Mandatory=$true)][ValidateSet('preflight','record')][string]$Action,[string]$RunIdentity='')
    foreach($value in @($ProjectId,$UnitId,$AttemptId)){if($value-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'){throw "Authority report identity is invalid: $value"}}
    if(-not$RunIdentity){$RunIdentity=[guid]::NewGuid().ToString('N')};$safe=($RunIdentity-replace'[^a-zA-Z0-9-]','-').ToLowerInvariant();if($safe.Length-gt64){$safe=$safe.Substring(0,64)}
    $root=[IO.Path]::Combine([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),'rusty-morphospace-authority-reports',$ProjectId,$UnitId,$AttemptId,"$Action-$safe")
    if([IO.Directory]::Exists($root)){throw "Authority report directory already exists: $root"};[IO.Directory]::CreateDirectory($root)|Out-Null
    return [pscustomobject]@{root=$root;stdout=Join-Path $root 'stdout.txt';stderr=Join-Path $root 'stderr.txt';stage_result=Join-Path $root 'stage-result.json';failure_report=Join-Path $root 'failure-report.json'}
}

function Get-MorphospaceAuthorityFailureClassification {
    param([Parameter(Mandatory=$true)][string]$Message)
    if($Message-match'(?i)closure path is absent|missing closure'){return [pscustomobject]@{code='closure-missing';classification='input-capsule';next_action='fix-closure'}}
    if($Message-match'(?i)child host|declared command|Get-FileHash'){return [pscustomobject]@{code='host-capability';classification='host-probe';next_action='fix-runner'}}
    if($Message-match'(?i)content observation changed|drifted|stale'){return [pscustomobject]@{code='input-drift';classification='capsule';next_action='rebuild-capsule'}}
    if($Message-match'(?i)timed out|exceeded its registry timeout'){return [pscustomobject]@{code='validator-timeout';classification='owner-validator';next_action='rerun-preflight'}}
    if($Message-match'(?i)did not emit|owner output'){return [pscustomobject]@{code='owner-output-missing';classification='owner-validator';next_action='fix-runner'}}
    if($Message-match'(?i)output exceeded'){return [pscustomobject]@{code='output-limit';classification='owner-validator';next_action='fix-runner'}}
    return [pscustomobject]@{code='authority-stage-failed';classification='authority-runner';next_action='fix-runner'}
}

function Write-MorphospaceAuthorityStageResult {
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][string]$Stage,[Parameter(Mandatory=$true)][ValidateSet('pass','fail')][string]$Result,[Parameter(Mandatory=$true)][datetime]$StartedAt,[string]$CapsuleSha256='',[string]$RunnerReleaseSha256='',[string]$FailureReportPath='')
    $ended=[DateTime]::UtcNow;$document=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.authority_stage_result.v1';stage=$Stage;result=$Result;started_at=$StartedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');completed_at=$ended.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');elapsed_ms=[long]($ended-$StartedAt.ToUniversalTime()).TotalMilliseconds;capsule_sha256=if($CapsuleSha256){$CapsuleSha256}else{$null};runner_release_sha256=if($RunnerReleaseSha256){$RunnerReleaseSha256}else{$null};failure_report=if($FailureReportPath){$FailureReportPath}else{$null}}
    Write-MorphospaceReadinessJsonNoOverwrite $Context.stage_result $document;return $document
}

function Write-MorphospaceAuthorityFailureReport {
    param([Parameter(Mandatory=$true)][object]$Context,[Parameter(Mandatory=$true)][string]$Stage,[Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord]$ErrorRecord,[Parameter(Mandatory=$true)][datetime]$StartedAt,[string]$CapsuleSha256='',[string]$RunnerReleaseSha256='',[string[]]$CreatedOutputs=@())
    $message=[string]$ErrorRecord.Exception.Message;$class=Get-MorphospaceAuthorityFailureClassification $message;$ended=[DateTime]::UtcNow
    $streams=@();foreach($item in @([pscustomobject]@{kind='stdout';path=$Context.stdout},[pscustomobject]@{kind='stderr';path=$Context.stderr})){if([IO.File]::Exists([string]$item.path)){$text=[IO.File]::ReadAllText([string]$item.path,[Text.UTF8Encoding]::new($false));$tail=if($text.Length-gt4096){$text.Substring($text.Length-4096)}else{$text};$streams+=[pscustomobject][ordered]@{kind=$item.kind;path=[string]$item.path;sha256=Get-MorphospaceReadinessSha256 ([string]$item.path);tail=$tail}}}
    $document=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.authority_failure_report.v1';stage=$Stage;failure_code=$class.code;classification=$class.classification;summary=$message;exception_type=$ErrorRecord.Exception.GetType().FullName;exit_code=$null;started_at=$StartedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');completed_at=$ended.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');elapsed_ms=[long]($ended-$StartedAt.ToUniversalTime()).TotalMilliseconds;capsule_sha256=if($CapsuleSha256){$CapsuleSha256}else{$null};runner_release_sha256=if($RunnerReleaseSha256){$RunnerReleaseSha256}else{$null};streams=$streams;created_outputs=@($CreatedOutputs);next_action=$class.next_action}
    Write-MorphospaceReadinessJsonNoOverwrite $Context.failure_report $document;return $document
}

Microsoft.PowerShell.Core\Export-ModuleMember -Function Get-MorphospaceReadinessSha256,Write-MorphospaceReadinessJsonNoOverwrite,New-MorphospaceAuthorityRunnerReleaseV1,Test-MorphospaceAuthorityRunnerReleaseV1,Invoke-MorphospaceAuthorityHostProbe,Test-MorphospaceAuthorityHostCapabilitiesV1,New-MorphospaceAuthorityInputCapsuleV1,Test-MorphospaceAuthorityInputCapsuleV1,New-MorphospaceAuthorityPreflightV1,Test-MorphospaceAuthorityPreflightV1,New-MorphospaceAuthorityReportContext,Write-MorphospaceAuthorityStageResult,Write-MorphospaceAuthorityFailureReport
