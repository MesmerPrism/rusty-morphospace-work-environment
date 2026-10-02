[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CandidateFreeze.psm1') -Force
$protocolModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$compatibilityModule = Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkCompatibility.psm1') -Force -PassThru
$repreparationModule = Import-Module (Join-Path $PSScriptRoot 'DevelopmentEnvelopeRepreparation.psm1') -PassThru
$automationModule = Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force -PassThru
$transitionLedgerModule = Get-Module -All | Where-Object { $_.Path -eq (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') } | Select-Object -Last 1
. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wef-current-work-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$passed = 0
function Invoke-ActualValidator([string]$OwnerRoot, [string]$Workspace, [bool]$LiveOnly) {
    $arguments = @('-NoProfile','-File',(Join-Path $OwnerRoot 'scripts/Test-WorkflowContracts.ps1'),'-RepoRoot',$OwnerRoot,'-SkipOwnerSelfTests')
    if ($Workspace) { $arguments += @('-WorkspaceRoot',$Workspace,'-RepositoryMapPath',(Join-Path $Workspace 'repository-map.json'),'-CurrentWorkOnly') }
    if ($LiveOnly) { $arguments += '-CurrentWorkspaceOnly' }
    $text = (& pwsh @arguments 2>&1 | Out-String)
    return [pscustomobject]@{ exit_code=$LASTEXITCODE; text=$text }
}
function Assert-Result($Result,[bool]$Pass,[string]$Name) {
    if (($Result.exit_code -eq 0) -ne $Pass) { throw "Current workspace validation case '$Name' failed: $($Result.text)" }
    $script:passed++
}
try {
    # The shared fixture uses real preparation/admission and transition producers.
    $fixture = New-EnvelopeAdmissionPreparedFixture -Root (Join-Path $testRoot 'fixture') -RepositoryRoot $repoRoot -TransitionLedgerModule $transitionLedgerModule -OwnerProducedPreparation
    $workspace = $fixture.workspace
    $admissionPath = Join-Path $testRoot 'admission.json'
    Write-EnvelopeJson $admissionPath $fixture.admission_template
    Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $workspace -DevelopmentUnitAdmission $admissionPath -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $admissionPath) -OutPath (Join-Path $workspace 'receipts/u002-admission.json') -Execute | Out-Null
    foreach ($action in @('Ready','Claim')) {
        Invoke-MorphospaceWorkUnitAutomation -Action $action -WorkspaceRoot $workspace -UnitId u002 -RepoMapPath (Join-Path $workspace 'repository-map.json') -OutPath (Join-Path $workspace "receipts/$action-action.json") -Execute | Out-Null
    }
    Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $true 'live prepared current owner'
    $eventPath = Join-Path $workspace 'iteration-events.jsonl'
    $eventBytes = [IO.File]::ReadAllBytes($eventPath)
    try {
        [IO.File]::AppendAllText($eventPath, "{`"schema`":`"invalid`"}`n", [Text.UTF8Encoding]::new($false))
        Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $false 'changed event suffix'
    } finally { [IO.File]::WriteAllBytes($eventPath,$eventBytes) }
    $receiptPath = Join-Path $workspace 'receipts/u002-envelope.json'
    $receiptBytes = [IO.File]::ReadAllBytes($receiptPath)
    try {
        [IO.File]::AppendAllText($receiptPath,' ',[Text.UTF8Encoding]::new($false))
        Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $false 'changed raw owner receipt'
    } finally { [IO.File]::WriteAllBytes($receiptPath,$receiptBytes) }
    $dependencyPath = Join-Path $workspace 'source-composition.json'
    $dependencyBytes = [IO.File]::ReadAllBytes($dependencyPath)
    try {
        [IO.File]::AppendAllText($dependencyPath,' ',[Text.UTF8Encoding]::new($false))
        Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $false 'changed source-composition pin'
    } finally { [IO.File]::WriteAllBytes($dependencyPath,$dependencyBytes) }
    Assert-Result (Invoke-ActualValidator $repoRoot $workspace $true) $true 'restored live closure'
    # A pointer with an absent resolver is denied by the early production check.
    $unitPath = Join-Path $workspace 'iteration-units/u002.json'
    $unitBytes = [IO.File]::ReadAllBytes($unitPath)
    try {
        $unit = Read-EnvelopeProtocolJson $unitPath
        $contextPath = Join-Path $workspace 'local/precheck-context.json'
        Write-EnvelopeJson $contextPath @{resolver=@{path='local/absent-resolver.json';sha256=('0'*64)}}
        $unit | Add-Member -NotePropertyName tooling_context -NotePropertyValue @{path='local/precheck-context.json';sha256=(Get-EnvelopeFileSha256 $contextPath)}
        Write-EnvelopeJson $unitPath $unit
        $result = Invoke-ActualValidator $repoRoot $workspace $true
        Assert-Result $result $false 'absent resolver early denial'
        if ($result.text -notmatch 'absent-resolver.json') { throw 'Missing resolver did not fail at the required input check.' }
    } finally { [IO.File]::WriteAllBytes($unitPath,$unitBytes) }
    # Materialize only tracked owner inputs; overlay the exact candidate validator.
    $ownerCopy = Join-Path $testRoot 'owner'
    [void][IO.Directory]::CreateDirectory($ownerCopy)
    $archive = Join-Path $testRoot 'owner.tar'
    & git -C $repoRoot archive --format=tar --output=$archive HEAD scripts schemas templates manifests examples skills
    if ($LASTEXITCODE -ne 0) { throw 'Owner fixture archive failed.' }
    & tar -xf $archive -C $ownerCopy
    if ($LASTEXITCODE -ne 0) { throw 'Owner fixture extraction failed.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-WorkflowContracts.ps1') -Destination (Join-Path $ownerCopy 'scripts/Test-WorkflowContracts.ps1')
    Invoke-EnvelopeGit $ownerCopy @('-c','init.defaultBranch=fixture','-c','init.templateDir=','init') | Out-Null
    Invoke-EnvelopeGit $ownerCopy @('add','scripts','schemas','templates','manifests','examples','skills') | Out-Null
    $emptyHooks = Join-Path $testRoot 'empty-hooks'
    [void][IO.Directory]::CreateDirectory($emptyHooks)
    Invoke-EnvelopeGit $ownerCopy @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c',"core.hooksPath=$emptyHooks",'commit','-m','owner-fixture') | Out-Null
    Assert-Result (Invoke-ActualValidator $ownerCopy '' $false) $true 'default owner conformance'
    [IO.File]::WriteAllText((Join-Path $ownerCopy 'templates/project.spec.v2.example.json'),'{}',[Text.UTF8Encoding]::new($false))
    Assert-Result (Invoke-ActualValidator $ownerCopy '' $false) $false 'default retains static negative fixtures'
    Assert-Result (Invoke-ActualValidator $ownerCopy $workspace $true) $true 'live mode does not repeat owner fixtures'
    Assert-Result (Invoke-ActualValidator $repoRoot '' $true) $false 'live mode requires explicit workspace flags'
    Write-Host "Current workspace validation: $passed production cases passed; static owner conformance remains separate from fresh live guards."
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
