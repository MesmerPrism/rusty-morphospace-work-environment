param(
    [ValidateSet("Inspect", "Acquire", "Release")][string]$Action = "Inspect",
    [string]$RegistryRoot = "",
    [string]$ClaimId = "",
    [string]$ProjectId = "",
    [string]$UnitId = "",
    [ValidateSet("", "repo-path", "build-output", "android-package", "headset", "property-namespace", "staging-namespace", "bridge-port")][string]$ResourceKind = "",
    [string]$ResourceId = "",
    [ValidateSet("exclusive", "shared-read")][string]$Mode = "exclusive",
    [ValidateRange(1, 1440)][int]$DurationMinutes = 60,
    [switch]$Execute
)

$ErrorActionPreference="Stop"
Import-Module (Join-Path $PSScriptRoot "lib\MorphospaceProtocolCommon.psm1") -Force
if([string]::IsNullOrWhiteSpace($RegistryRoot)){$RegistryRoot=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "RustyMorphospace\resource-claims"}
$root=[IO.Path]::GetFullPath($RegistryRoot);$statePath=Join-Path $root "claims.json";$mutexName="Local\RustyMorphospaceResourceClaims-"+(Get-MorphospaceSha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($root))).Substring(0,24);$mutex=[Threading.Mutex]::new($false,$mutexName)
function Read-State{if(-not[IO.File]::Exists($statePath)){return [pscustomobject][ordered]@{schema="rusty.morphospace.workflow.resource_claim_registry.v1";revision=0;claims=@()}};return Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json}
function Normalize-ResourceId{param([string]$Kind,[string]$Id)$value=$Id.Trim();if($Kind-in@("repo-path","build-output")){return [IO.Path]::GetFullPath($value).TrimEnd('\','/').ToLowerInvariant()};if($Kind-eq"property-namespace"){return $value.TrimEnd('.').ToLowerInvariant()};return $value.ToLowerInvariant()}
function Test-Overlap{param($A,$B)if([string]$A.resource_kind-ne[string]$B.resource_kind){return $false};$left=Normalize-ResourceId ([string]$A.resource_kind) ([string]$A.resource_id);$right=Normalize-ResourceId ([string]$B.resource_kind) ([string]$B.resource_id);if([string]$A.resource_kind-in@("repo-path","build-output")){$sep=[IO.Path]::DirectorySeparatorChar;return $left-eq$right-or$left.StartsWith($right+$sep)-or$right.StartsWith($left+$sep)};if([string]$A.resource_kind-eq"property-namespace"){return $left-eq$right-or$left.StartsWith($right+".")-or$right.StartsWith($left+".")};return $left-eq$right}
function Write-State{param($State)[void][IO.Directory]::CreateDirectory($root);$tmp="$statePath.pending-$([guid]::NewGuid().ToString('N'))";[IO.File]::WriteAllText($tmp,($State|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $statePath -Force}
$acquired=$false
try{$acquired=$mutex.WaitOne(5000);if(-not$acquired){throw "Resource claim registry is busy: $root"};$state=Read-State;$now=[DateTime]::UtcNow
    if($Action-eq"Inspect"){$state|ConvertTo-Json -Depth 12;return}
    if($Action-eq"Acquire"){
        foreach($field in @(@{n="ClaimId";v=$ClaimId},@{n="ProjectId";v=$ProjectId},@{n="UnitId";v=$UnitId},@{n="ResourceKind";v=$ResourceKind},@{n="ResourceId";v=$ResourceId})){if([string]::IsNullOrWhiteSpace([string]$field.v)){throw "-$($field.n) is required for Acquire."}}
        if($ClaimId-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'-or$ProjectId-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'-or$UnitId-notmatch'^[a-z0-9][a-z0-9-]{1,191}$'){throw "Claim, project, and unit IDs must be portable lowercase IDs."}
        $candidate=[pscustomobject][ordered]@{schema="rusty.morphospace.workflow.resource_claim.v1";claim_id=$ClaimId;project_id=$ProjectId;unit_id=$UnitId;resource_kind=$ResourceKind;resource_id=Normalize-ResourceId $ResourceKind $ResourceId;mode=$Mode;acquired_at=$now.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ");expires_at=$now.AddMinutes($DurationMinutes).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ");released_at=$null;status="active"}
        foreach($claim in @($state.claims)){if([string]$claim.claim_id-eq$ClaimId){throw "Resource claim ID already exists: $ClaimId"};$expires=[DateTime]::Parse([string]$claim.expires_at,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal);if([string]$claim.status-eq"active"-and$expires-gt$now-and(Test-Overlap $candidate $claim)-and($Mode-eq"exclusive"-or[string]$claim.mode-eq"exclusive")){throw "Resource conflicts with active claim '$($claim.claim_id)' owned by $($claim.project_id)/$($claim.unit_id)."}}
        if(-not$Execute){[pscustomobject][ordered]@{schema="rusty.morphospace.workflow.resource_claim_plan.v1";action="acquire";would_write=$false;claim=$candidate}|ConvertTo-Json -Depth 10;return}
        $state.revision=[long]$state.revision+1;$state.claims=@($state.claims)+@($candidate);Write-State $state;$candidate|ConvertTo-Json -Depth 10;return
    }
    if([string]::IsNullOrWhiteSpace($ClaimId)){throw "-ClaimId is required for Release."};$match=@($state.claims|Where-Object{[string]$_.claim_id-eq$ClaimId});if($match.Count-ne1){throw "Resource claim was not found exactly once: $ClaimId"};if([string]$match[0].status-ne"active"){throw "Resource claim is not active: $ClaimId"}
    if(-not$Execute){[pscustomobject][ordered]@{schema="rusty.morphospace.workflow.resource_claim_plan.v1";action="release";would_write=$false;claim_id=$ClaimId}|ConvertTo-Json;return}
    $match[0].status="released";$match[0].released_at=$now.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ");$state.revision=[long]$state.revision+1;Write-State $state;$match[0]|ConvertTo-Json -Depth 8
}finally{if($acquired){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
