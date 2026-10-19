param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
$admissionModule=Import-Module (Join-Path $PSScriptRoot 'DevelopmentUnitAdmission.psm1') -Force -PassThru
$protocolModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -PassThru
$ledgerModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1') -PassThru
. (Join-Path $PSScriptRoot 'test-support/DevelopmentAdmissionFixture.ps1')
$lifecycle=Get-Content (Join-Path $repoRoot 'manifests/workflow-lifecycle.portable.json') -Raw|ConvertFrom-Json
$root=Join-Path ([IO.Path]::GetTempPath()) ('workenv-admission-instructions-'+[guid]::NewGuid().ToString('N'))
try {
    $fixture=New-EnvelopeAdmissionPreparedFixture -Root $root -RepositoryRoot $repoRoot -TransitionLedgerModule $ledgerModule
    $template=Copy-Envelope $fixture.admission_template
    $unit=Copy-Envelope $template.unit
    $unit.change_categories=@('authority');$unit.instruction_impact='review';$unit.instruction_none_justification=$null
    $unit.instruction_surfaces=@(
        [pscustomobject]@{surface_kind='agents';path='AGENTS.md';owner='fixture';change_reason='Review authority routing.';action='review-no-change';status='planned';validation='Owner review required.';skill_id=$null},
        [pscustomobject]@{surface_kind='readme';path='README.md';owner='fixture';change_reason='Review authority routing.';action='review-no-change';status='planned';validation='Owner review required.';skill_id=$null},
        [pscustomobject]@{surface_kind='skill';path='<skills-root>/rusty-morphospace/SKILL.md';owner='fixture';change_reason='Review authority routing.';action='review-no-change';status='planned';validation='Owner review required.';skill_id='rusty-morphospace'},
        [pscustomobject]@{surface_kind='skill';path='<skills-root>/system-engineering/SKILL.md';owner='fixture';change_reason='Review authority routing.';action='review-no-change';status='planned';validation='Owner review required.';skill_id='system-engineering'}
    )
    function CheckDeclaration([object]$value){&$admissionModule {param($u,$l) Assert-AdmissionInstructionDeclaration $u $l} $value $lifecycle}
    function Pass([string]$name,[object]$value){CheckDeclaration $value;Write-Output "PASS $name"}
    Pass 'planned feature review declaration does not claim completion' $unit
    $updated=Copy-Envelope $unit;$updated.instruction_surfaces[0].action='update';$updated.instruction_impact='update';Pass 'actual update selects update impact' $updated
    $validation=Copy-Envelope $unit;$validation|Add-Member work_mode 'validation-only';$validation.change_categories=@('validation')
    $validation|Add-Member claim_requirements ([pscustomobject]@{minimum_free_disk_mib=0;required_tools=@();product_inputs=@()})
    Assert-EnvelopeFixtureSchema $validation 'iteration-unit.schema.json' 'valid validation-only declaration'
    Pass 'schema-valid validation-only review declaration' $validation
    $none=Copy-Envelope $unit;$none.change_categories=@('implementation');$none.instruction_impact='none';$none.instruction_surfaces=@();$none.instruction_none_justification='No instruction decision changes.';Pass 'untriggered justified none' $none
    $alias=Copy-Envelope $unit;$alias.change_categories=@('module-composition');$alias.instruction_surfaces+=,[pscustomobject]@{surface_kind='skill';path='<skills-root>/rust-work-graph/SKILL.md';owner='fixture';change_reason='Review source routing.';action='review-no-change';status='planned';validation='Owner review required.';skill_id='rust-work-graph'};Pass 'alias selects canonical skill routing' $alias
    # An invalid project sentinel proves the real admission entrypoint rejects
    # authored declarations before reading project/source/tooling authority.
    [IO.File]::WriteAllText((Join-Path $fixture.workspace 'project.spec.json'),'not json')
    foreach($kind in @('agents','readme')){
        $bad=Copy-Envelope $validation;($bad.instruction_surfaces|Where-Object surface_kind -eq $kind).action='update'
        $message='';try{CheckDeclaration $bad}catch{$message=$_.Exception.Message}
        Assert-Envelope ($message-ceq'Admission instruction declaration: validation-only required entrypoints must use review-no-change.') "static validation-only declaration accepted update $kind"
        $input=Copy-Envelope $template;$input.unit=$bad;$path=Join-Path $root "validation-update-$kind.json";Write-EnvelopeJson $path $input
        foreach($execute in @($false,$true)){
            $before=Get-EnvelopeWorkspaceByteInventorySha256 $fixture.workspace
            $message='';try{Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $fixture.workspace -DevelopmentUnitAdmission $path -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $path) -Execute:$execute|Out-Null}catch{$message=$_.Exception.Message}
            # Today's unit schema also rejects this action. Keep that earlier
            # denial rather than bypassing it to reach the static helper.
            Assert-Envelope (($message.StartsWith('The JSON is not valid with the schema:')-or$message-ceq'Admission instruction declaration: validation-only required entrypoints must use review-no-change.')-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $fixture.workspace)) "actual admission accepted validation-only $kind update or missed its declaration denial: $message"
        }
        Write-Output "PASS static parity and actual schema preview/execute reject validation-only $kind update before authority reads or writes"
    }
    foreach($kind in @('triggered-none','missing-agents','missing-router','missing-skill','duplicate-skill','update-impact-without-update','review-impact-with-update','alias-missing-skill','none-with-surfaces','none-without-justification')){
        $bad=Copy-Envelope $unit
        switch($kind){
            'triggered-none'{$bad.instruction_impact='none';$bad.instruction_surfaces=@();$bad.instruction_none_justification='Incorrect declaration.'}
            'missing-agents'{$bad.instruction_surfaces=@($bad.instruction_surfaces|Where-Object surface_kind -ne 'agents')}
            'missing-router'{$bad.instruction_surfaces=@($bad.instruction_surfaces|Where-Object surface_kind -ne 'readme')}
            'missing-skill'{$bad.instruction_surfaces=@($bad.instruction_surfaces|Where-Object skill_id -ne 'system-engineering')}
            'duplicate-skill'{$extra=Copy-Envelope $bad.instruction_surfaces[2];$extra.path='<skills-root>/another/SKILL.md';$bad.instruction_surfaces+=,$extra}
            'update-impact-without-update'{$bad.instruction_impact='update'}
            'review-impact-with-update'{$bad.instruction_surfaces[0].action='update'}
            'alias-missing-skill'{$bad.change_categories=@('module-composition')}
            'none-with-surfaces'{$bad.instruction_impact='none';$bad.instruction_none_justification='Incorrect declaration.'}
            'none-without-justification'{$bad=Copy-Envelope $none;$bad.instruction_none_justification=$null}
        }
        $input=Copy-Envelope $template;$input.unit=$bad
        $path=Join-Path $root "$kind.json";Write-EnvelopeJson $path $input
        if($kind-in@('none-with-surfaces','none-without-justification','alias-missing-skill')){
            $message='';try{CheckDeclaration $bad}catch{$message=$_.Exception.Message}
            Assert-Envelope ($message.StartsWith('Admission instruction declaration:')) "pure declaration accepted $kind"
            Write-Output "PASS pure declaration rejects already schema-invalid $kind"
            continue
        }
        Assert-EnvelopeFixtureSchema $input 'development-unit-admission-v1.schema.json' $kind
        Assert-EnvelopeFixtureSchema $bad 'iteration-unit.schema.json' $kind
        foreach($execute in @($false,$true)){
            $before=Get-EnvelopeWorkspaceByteInventorySha256 $fixture.workspace
            $message='';try{Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $fixture.workspace -DevelopmentUnitAdmission $path -ExpectedDevelopmentUnitAdmissionSha256 (Get-EnvelopeFileSha256 $path) -Execute:$execute|Out-Null}catch{$message=$_.Exception.Message}
            Assert-Envelope ($message.StartsWith('Admission instruction declaration:')-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $fixture.workspace)) "real admission did not reject $kind before reads/writes (execute=$execute): $message"
        }
        Write-Output "PASS actual preview/execute rejects $kind before authority reads or writes"
    }
    $good=Copy-Envelope $template;$good.unit=$unit;$path=Join-Path $root 'valid.json';Write-EnvelopeJson $path $good
    $expectedProjectError="Invalid JSON in '$(Join-Path $fixture.workspace 'project.spec.json')': Invalid JSON token at offset 0."
    $message='';try{Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $fixture.workspace -DevelopmentUnitAdmission $path|Out-Null}catch{$message=$_.Exception.Message}
    Assert-Envelope ($message-ceq$expectedProjectError) "valid declaration did not reach unchanged project parser: $message"
    Write-Output 'PASS valid declaration retains subsequent authority checks'
    $good.unit=$validation;$path=Join-Path $root 'valid-validation-only.json';Write-EnvelopeJson $path $good
    $message='';try{Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $fixture.workspace -DevelopmentUnitAdmission $path|Out-Null}catch{$message=$_.Exception.Message}
    Assert-Envelope ($message-ceq$expectedProjectError) "valid validation-only declaration did not reach unchanged project parser: $message"
    Write-Output 'PASS schema-valid validation-only declaration retains subsequent authority checks'
    $old=Copy-Envelope $template;$old.unit=Copy-Envelope $none;$old.unit.change_categories=@('authority');$path=Join-Path $root 'retained.json';Write-EnvelopeJson $path $old
    $intent=Join-Path $fixture.workspace "receipts/transactions/$($old.admission_id)-admitted-transition.intent.json";[IO.Directory]::CreateDirectory((Split-Path $intent -Parent))|Out-Null;[IO.File]::WriteAllText($intent,'{}')
    $before=Get-EnvelopeWorkspaceByteInventorySha256 $fixture.workspace
    $message='';try{Invoke-MorphospaceAdmitDevelopmentUnit -WorkspaceRoot $fixture.workspace -DevelopmentUnitAdmission $path|Out-Null}catch{$message=$_.Exception.Message}
    Assert-Envelope ($message-ceq$expectedProjectError-and$before-ceq(Get-EnvelopeWorkspaceByteInventorySha256 $fixture.workspace)) "retained intent acquired new declaration policy or bypassed project parsing: $message"
    Write-Output 'PASS existing intent skips new declaration policy and still fails unchanged invalid authority'
}finally{
    if(Test-Path -LiteralPath $root){
        $resolved=(Resolve-Path -LiteralPath $root).Path
        $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not$resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-notlike'workenv-admission-instructions-*'){throw 'Unsafe fixture cleanup path.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
