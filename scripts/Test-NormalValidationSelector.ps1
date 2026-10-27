[CmdletBinding()]
param([switch]$SelfTest,[switch]$DeclaredTierOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force

function Assert-SelectorTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Normal-validation selector self-test failed: $Message" }
}

function Write-TestJson([string]$Path, [object]$Value) {
    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 32) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-TestTextSha256([string]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-TestCanonicalPathSha256([string]$Path) {
    $canonical = [IO.Path]::GetFullPath($Path)
    $identity = if ([IO.Path]::DirectorySeparatorChar -eq '\') { $canonical.Replace('/', '\').ToUpperInvariant() } else { $canonical }
    return Get-TestTextSha256 $identity
}

function Get-TestUnitContractSha256([object]$Unit) {
    $copy = (($Unit | ConvertTo-Json -Depth 100) | ConvertFrom-Json)
    if ($copy.PSObject.Properties.Name -contains 'status') {
        $copy.PSObject.Properties.Remove('status')
    }
    return Get-MorphospaceCanonicalJsonSha256 $copy
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $output = @(& git -C $RepositoryPath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Test Git command failed: git -C '$RepositoryPath' $($Arguments -join ' '): $($output -join ' ')"
    }
    return ($output -join "`n").Trim()
}

function Write-TestCreateNewJson([string]$Path, [object]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($Value | ConvertTo-Json -Depth 32) + "`n"))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) }
    finally { $stream.Dispose() }
}

function New-SelectorValidationReceipt {
    param(
        [string]$Workspace,
        [string]$UnitId,
        [ValidateSet('pass', 'fail')][string]$Result,
        [object]$MatrixRow,
        [string]$EvidencePath,
        [string]$ReceiptLeaf,
        [ValidateSet('quick','standard','deep')][string]$Tier='quick',
        [object]$RepositoryRevision = $null
    )

    $status = if ($Result -ceq 'pass') { 'pass' } else { 'fail' }
    $evidenceHash = (Get-FileHash -LiteralPath $EvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $receiptPath = Join-Path (Join-Path $Workspace 'receipts') $ReceiptLeaf
    $repositoryRevisions = @()
    if ($null -ne $RepositoryRevision) { $repositoryRevisions = @([pscustomobject]$RepositoryRevision) }
    Write-TestJson $receiptPath ([ordered]@{
        '$schema' = '../schemas/validation-receipt.schema.json'
        schema = 'rusty.morphospace.workflow.validation_receipt.v1'
        receipt_id = "$UnitId-$Result-selector-validation"
        project_id = 'selector-consumer-test'
        unit_id = $UnitId
        created_at = '2026-08-29T06:00:00Z'
        tier = $Tier
        result = $Result
        repository_revisions = $repositoryRevisions
        changed_paths = @()
        artifacts = @([ordered]@{
            artifact_id = 'selected-quick-evidence'
            kind = 'test-log'
            path = [IO.Path]::GetFullPath($EvidencePath)
            sha256 = $evidenceHash
        })
        criteria = @([ordered]@{
            acceptance_id = 'selector-self-test'
            status = $status
            command = 'Test-NormalValidationSelector.ps1 -SelfTest'
            evidence_refs = @('selected-quick-evidence')
        })
        gates = @([ordered]@{
            gate_id = [string]$MatrixRow.gate_id
            status = $status
            command = [string]$MatrixRow.command
            evidence_refs = @('selected-quick-evidence')
        })
        device_validation = $null
    })
    return $receiptPath
}

function Assert-Rejected([string]$Name, [string]$Pattern, [scriptblock]$Action) {
    $rejected = $false
    $observed = '<no exception>'
    try { & $Action | Out-Null }
    catch { $observed = $_.Exception.Message; $rejected = $observed -like $Pattern }
    Assert-SelectorTest $rejected "$Name was not rejected with '$Pattern' (observed: $observed)"
}

if (-not $SelfTest) { throw 'Test-NormalValidationSelector.ps1 requires -SelfTest.' }

# The declared-tier contract is separate from the retained workspace Quick v1.
$declaredTierSchema = Join-Path $repoRoot 'schemas/normal-validation-selector-v2.schema.json'
Assert-SelectorTest (Test-Path -LiteralPath $declaredTierSchema -PathType Leaf) 'declared-tier v2 schema is absent'
$declaredTierContract = Get-Content -LiteralPath $declaredTierSchema -Raw | ConvertFrom-Json -Depth 64
Assert-SelectorTest ((@($declaredTierContract.properties.selection.properties.tier.enum) -join '|') -ceq 'quick|standard|deep') 'v2 must declare every ordinary tier without relaxing v1'
Assert-SelectorTest ($declaredTierContract.properties.selection.properties.producer.properties.path.const -ceq 'scripts/Invoke-WorkflowCurrentValidation.ps1') 'v2 producer is not the fixed bound-owner entrypoint'
Assert-SelectorTest ((Get-Content -LiteralPath (Join-Path $repoRoot 'schemas/normal-validation-selector-v1.schema.json') -Raw | ConvertFrom-Json -Depth 64).properties.selection.properties.tier.const -ceq 'quick') 'v1 Quick contract changed'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-normal-selector-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $testRoot 'project'
$workspace = Join-Path $projectRoot 'morphospace'
$evidenceRoot = Join-Path $testRoot 'evidence'
$unitId = 'unit-selector-003'
$freezeId = 'unit-selector-003-candidate'
$selectorId = 'unit-selector-003-quick'
$declaredProfile = 'quick-scaffold'
$declaredCommand = 'Run the activation scaffold and require legacy_files_read=0.'
$selectorRelative = "validation-authority/selectors/$selectorId.json"
$selectorPath = Join-Path $workspace ($selectorRelative -replace '/', '\')
$producerRelative = 'tools/Test-UnitSelector003Quick.ps1'
$producerPath = Join-Path $workspace ($producerRelative -replace '/', '\')
$receiptRelative = "receipts/$freezeId.json"
$receiptPath = Join-Path $workspace ($receiptRelative -replace '/', '\')
$unitRelative = "iteration-units/$unitId.json"
$unitPath = Join-Path $workspace ($unitRelative -replace '/', '\')
$repoMapPath = Join-Path $testRoot 'repository-map.json'
$evidenceName = 'unit-selector-003-quick-evidence.json'
$evidencePath = Join-Path $evidenceRoot $evidenceName
$fixed = '2026-08-29T06:00:00.0000000Z'

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
    $projectPath = Join-Path $workspace 'project.spec.json'
    $project = [ordered]@{
        schema = 'rusty.morphospace.workflow.project_spec.v2'; project_id = 'selector-consumer-test'; revision = 1
        owner = 'selector-consumer-owner'; purpose = 'Exercise exact external Quick selection.'
        activation_model = [ordered]@{ default = 'disabled'; unlisted_modules = 'inert'; runtime_rule = 'selected-lock-and-runtime-input' }
        composition = [ordered]@{ selected_features = @(); denied_features = @(); selected_modules = @(); denied_modules = @(); allowed_permissions = @(); denied_permissions = @(); data_classes = @() }
        authority_map = @([ordered]@{ parameter = 'project.composition'; owner = 'selector-consumer-owner'; adapters = @() })
        repositories = @([ordered]@{ repo_id = 'project-shell'; role = 'planning'; path = '..'; allowed_paths = @('morphospace/') })
        modules = @(); non_scope = @('Product, build, device, acceptance, and publication work.')
        validation_profiles = @([ordered]@{ profile_id = $declaredProfile; commands = @('activation-only fixture command') },[ordered]@{profile_id='workflow-current';commands=@('Reserved current-work fixture declaration.')})
        acceptance_profiles = @([ordered]@{ profile_id = 'manual-review'; commands = @('Independent review is required.') })
        release_policy = [ordered]@{ versioning = 'semver'; commit_policy = 'Fixture only.'; push_checkpoint = 'manual-owner-review'; source_first = $true; planning_last = $true; force_push_allowed = $false }
        public_boundary = [ordered]@{ mode = 'public'; private_overlay = 'local/'; prohibited_evidence = @('device serials') }
    }
    Write-TestJson $projectPath $project
    Write-TestJson $repoMapPath ([ordered]@{
        schema = 'rusty.morphospace.workflow.repository_map.v1'
        repositories = @([ordered]@{ repo_id = 'project-shell'; path = $projectRoot; role = 'planning' })
    })

    Write-TestJson (Join-Path $workspace 'feature.lock.json') ([ordered]@{
        schema = 'rusty.morphospace.workflow.feature_lock.v2'; project_id = 'selector-consumer-test'; project_revision = 1; revision = 1
        generated_at = $fixed; resolver_version = 'selector-self-test/1'; lock_fingerprint = ('a' * 64)
        default_activation = 'disabled'; activation_rule = 'selected-lock-and-runtime-input'; selected_features = @(); denied_features = @(); features = @()
        effect_union = [ordered]@{ permissions = @(); services = @(); activities = @(); queries = @(); tools = @(); assets = @(); shaders = @(); native_libraries = @(); commands = @(); routes = @(); streams = @(); inputs = @(); scenes = @(); markers = @() }
    })
    foreach ($directory in @('iteration-units', 'receipts', 'validation-authority/selectors', 'tools')) {
        [IO.Directory]::CreateDirectory((Join-Path $workspace ($directory -replace '/', '\\'))) | Out-Null
    }

    [IO.Directory]::CreateDirectory((Split-Path -Parent $producerPath)) | Out-Null
    $producerText = @'
param([Parameter(Mandatory=$true)][string]$WorkspaceRoot,[Parameter(Mandatory=$true)][string]$EvidencePath)
throw 'The selector consumer must never execute the evidence producer.'
'@
    [IO.File]::WriteAllText($producerPath, $producerText, [Text.UTF8Encoding]::new($false))

    $freezeReceipt = [ordered]@{
        schema = 'rusty.morphospace.workflow.candidate_freeze.v1'
        freeze_id = $freezeId
        project_id = 'selector-consumer-test'
        unit_id = $unitId
        final_repositories = @([ordered]@{
            repo_id = 'product-development'
            commit = '1111111111111111111111111111111111111111'
            tree = '2222222222222222222222222222222222222222'
        })
    }
    Write-TestJson $receiptPath $freezeReceipt
    $receiptSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $receiptPath).Hash.ToLowerInvariant()

    $unit = [ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_unit.v1'
        unit_id = $unitId
        project_id = 'selector-consumer-test'
        status = 'validating'
        objective = 'Prove exact selector dispatch without executing validation.'
        change_categories = @('workflow')
        instruction_impact = 'none'
        instruction_surfaces = @()
        instruction_none_justification = 'The fixture has no instruction surface.'
        prerequisites = @()
        allowed_repositories = @([ordered]@{ repo_id = 'project-shell'; allowed_paths = @('morphospace/') })
        non_scope = @('Product, build, device, acceptance, and publication work.')
        acceptance = @([ordered]@{ acceptance_id = 'selector-self-test'; proof = 'Focused test passes.'; command = 'Test-NormalValidationSelector.ps1 -SelfTest' })
        risk_tier = 'standard'
        device_requirement = 'none'
        validation = @([ordered]@{ profile_id = $declaredProfile; command = $declaredCommand })
        outputs = @('external evidence dispatch plan')
        commit_policy = 'Fixture only.'
        push_checkpoint = 'manual-owner-review'
        candidate_freeze = [ordered]@{ freeze_id = $freezeId; receipt_path = $receiptRelative; receipt_sha256 = $receiptSha256 }
    }
    Write-TestJson $unitPath $unit

    $statePath = Join-Path $workspace 'workspace.state.json'
    $state = [ordered]@{
        schema = 'rusty.morphospace.workflow.workspace_state.v2'; project_id = 'selector-consumer-test'; plan_revision = 1
        current_unit = $unitId; next_ready_unit = $null; last_event_id = 'unit-selector-003-validating'; last_accepted_receipt = $null
        repository_heads = @(); repository_checkpoints = @(); module_registry = [ordered]@{ lock_revision = 1; lock_fingerprint = ('a' * 64); modules = @() }
        capability_registry = @(); dirty_repositories = @(); blockers = @(); validation_checkpoint = $null; pending_push_bundle = $null
    }
    Write-TestJson $statePath $state

    $eventsPath = Join-Path $workspace 'iteration-events.jsonl'
    [IO.File]::WriteAllText($eventsPath, (([ordered]@{
        schema = 'rusty.morphospace.workflow.iteration_event.v1'; event_id = 'unit-selector-003-validating'; sequence = 1
        timestamp = $fixed; project_id = 'selector-consumer-test'; unit_id = $unitId; event_type = 'state-transition'
        summary = 'Synthetic validating state.'; receipts = @()
    } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))

    function New-SelectorDocument {
        param(
            [string]$DocumentSelectorId = $selectorId,
            [string]$OutputEvidencePath = $evidencePath,
            [string]$OutputEvidenceName = $evidenceName
        )
        return [ordered]@{
            '$schema' = 'https://github.com/MesmerPrism/rusty-morphospace-work-environment/schemas/normal-validation-selector-v1.schema.json'
            schema = 'rusty.morphospace.workflow.normal_validation_selector.v1'
            selector_id = $DocumentSelectorId
            project = [ordered]@{
                project_id = 'selector-consumer-test'; spec_path = 'project.spec.json'
                spec_raw_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $projectPath).Hash.ToLowerInvariant()
            }
            unit = [ordered]@{
                unit_id = $unitId; path = $unitRelative
                raw_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $unitPath).Hash.ToLowerInvariant()
                contract_sha256 = Get-TestUnitContractSha256 (Get-Content -Raw -LiteralPath $unitPath | ConvertFrom-Json)
            }
            declared_gate = [ordered]@{ profile_id = $declaredProfile; command_sha256 = Get-TestTextSha256 $declaredCommand }
            candidate_freeze = [ordered]@{
                freeze_id = $freezeId; receipt_path = $receiptRelative; receipt_sha256 = $receiptSha256
                final_repositories = @([ordered]@{
                    repo_id = 'product-development'; commit = '1111111111111111111111111111111111111111'; tree = '2222222222222222222222222222222222222222'
                })
            }
            selection = [ordered]@{
                tier = 'quick'
                producer = [ordered]@{
                    kind = 'workspace-powershell-evidence-v1'; path = $producerRelative
                    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $producerPath).Hash.ToLowerInvariant()
                }
                output_evidence = [ordered]@{
                    file_name = $OutputEvidenceName; schema = 'rusty.morphospace.test.unit003.quick-evidence.v1'
                    canonical_path_sha256 = Get-TestCanonicalPathSha256 $OutputEvidencePath
                    requires_create_new = $true
                }
            }
            does_not_authorize = @('Source, build, device, lifecycle, acceptance, and publication mutations remain unauthorized.')
        }
    }

    $positiveSelector = New-SelectorDocument
    $selectorModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceNormalValidationSelector.psm1') -PassThru
    $declaredMatrix=@([pscustomobject]@{order=1;gate_id="validation-$declaredProfile";kind='command';profile_id=$declaredProfile;command=$declaredCommand;disposition='required'})
    foreach($tier in @('quick','standard','deep')) {
        $tierUnit=$unit|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64
        $tierUnit.risk_tier=$tier
        $tierUnit.validation[0].profile_id='workflow-current'
        $tierMatrix=@([pscustomobject]@{order=1;gate_id='validation-workflow-current';kind='command';profile_id='workflow-current';command=$declaredCommand;disposition='required'})
        Write-TestJson $unitPath $tierUnit
        $v2=$positiveSelector|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64
        $v2.schema='rusty.morphospace.workflow.normal_validation_selector.v2'
        $v2.selection.tier=$tier
        $v2.declared_gate.profile_id='workflow-current'
        $v2.unit.raw_sha256=(Get-FileHash -LiteralPath $unitPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $v2.unit.contract_sha256=Get-TestUnitContractSha256 $tierUnit
        $v2.selection.producer.kind='bound-workflow-current-evidence-v2'
        $v2.selection.producer.path='scripts/Invoke-WorkflowCurrentValidation.ps1'
        $v2.selection.output_evidence.schema='rusty.morphospace.workflow.current_validation_evidence.v1'
        $v2|Add-Member tooling_context ([pscustomobject]@{path='tooling-contexts/context-test.json';sha256='a'*64;canonical_sha256='b'*64;protocol_id='tooling-context-v1'})
        Assert-SelectorTest (Test-Json -Json ($v2|ConvertTo-Json -Depth 64) -SchemaFile $declaredTierSchema) "v2 $tier schema refused"
        Write-TestJson $selectorPath $v2
        $v2Hash=(Get-FileHash -LiteralPath $selectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Rejected "v2 $tier cannot borrow unauthenticated tooling" '*exact live adopted tooling-context pointer*' {
            Resolve-MorphospaceNormalValidationSelector -WorkspaceRoot $workspace -SelectorReference $selectorRelative -ExpectedSelectorSha256 $v2Hash -EvidencePath $evidencePath -Spec ([pscustomobject]$project) -Unit $tierUnit -DeclaredValidationMatrix $tierMatrix -Action BeginValidation -ValidationTier $tier
        }
        $wrongTier=if($tier-ceq'deep'){'standard'}else{'deep'}
        Assert-Rejected "v2 $tier downgrade or mismatch" '*declared tier differs*' {
            Resolve-MorphospaceNormalValidationSelector -WorkspaceRoot $workspace -SelectorReference $selectorRelative -ExpectedSelectorSha256 $v2Hash -EvidencePath $evidencePath -Spec ([pscustomobject]$project) -Unit ([pscustomobject]$unit) -DeclaredValidationMatrix $tierMatrix -Action BeginValidation -ValidationTier $wrongTier
        }
        if($tier-cne'deep'){
            $riskBefore=$tierUnit.risk_tier;$tierUnit.risk_tier='deep'
            Assert-Rejected "v2 $tier below admitted Deep risk" '*may not downgrade*' {
                Resolve-MorphospaceNormalValidationSelector -WorkspaceRoot $workspace -SelectorReference $selectorRelative -ExpectedSelectorSha256 $v2Hash -EvidencePath $evidencePath -Spec ([pscustomobject]$project) -Unit $tierUnit -DeclaredValidationMatrix $tierMatrix -Action BeginValidation -ValidationTier $tier
            }
            $tierUnit.risk_tier=$riskBefore
        }
        foreach($damage in @('tier','profile','producer-path','producer-kind','evidence-type','context-protocol')) {
            $bad=$v2|ConvertTo-Json -Depth 64|ConvertFrom-Json -Depth 64
            switch($damage){'tier'{$bad.selection.tier='fast'};'profile'{$bad.declared_gate.profile_id='host-build'};'producer-path'{$bad.selection.producer.path='tools/CallerChosen.ps1'};'producer-kind'{$bad.selection.producer.kind='workspace-powershell-evidence-v1'};'evidence-type'{$bad.selection.output_evidence.schema='caller.chosen.v1'};'context-protocol'{$bad.tooling_context.protocol_id='caller-protocol'}}
            Assert-SelectorTest (-not(Test-Json -Json ($bad|ConvertTo-Json -Depth 64) -SchemaFile $declaredTierSchema -ErrorAction SilentlyContinue)) "v2 $tier schema accepted $damage"
        }
    }
    Write-TestJson $unitPath $unit
    # Typed-reader controls model terminal metadata explicitly; the complete
    # ToolingContext scenario separately earns the real Standard child closure.
    $readerSelector=$v2;$readerUnit=$tierUnit
    $readerMap='local/reader-map.json';Write-TestJson (Join-Path $workspace $readerMap) (Get-Content -LiteralPath $repoMapPath -Raw|ConvertFrom-Json)
    $validator=Join-Path $repoRoot 'scripts/Test-WorkflowContracts.ps1'
    $readerProducer=[pscustomobject]@{executor_root=$repoRoot;binding=$readerSelector.tooling_context;context=[pscustomobject]@{executor=[pscustomobject]@{commit='1'*40;tree='2'*40;closure=@([pscustomobject]@{path='scripts/Test-WorkflowContracts.ps1';sha256=(Get-FileHash -LiteralPath $validator).Hash.ToLowerInvariant()})};product_projection=[pscustomobject]@{repository_map=[pscustomobject]@{path=$readerMap;sha256=(Get-FileHash -LiteralPath (Join-Path $workspace $readerMap)).Hash.ToLowerInvariant()}}}}
    $readerSelection=[pscustomobject]@{unit_id=$readerSelector.unit.unit_id;unit_raw_sha256=$readerSelector.unit.raw_sha256;unit_contract_sha256=$readerSelector.unit.contract_sha256;tier='deep';selector_id=$readerSelector.selector_id;selector_path=$selectorRelative;selector_sha256='3'*64;evidence_path_sha256=$readerSelector.selection.output_evidence.canonical_path_sha256}
    $readerCommand=&$selectorModule {param($w,$p)Get-MorphospaceCurrentValidationCommand -WorkspaceRoot $w -ProducerObservation $p} $workspace $readerProducer
    function New-ReaderEvidence([bool]$Pass){
        $text=if($Pass){"Workflow contract validation passed for current project workspace; owner conformance not repeated.`n"}else{"Explicit modeled child failure.`n"}
        [IO.File]::WriteAllText(($evidencePath+'.stdout.bin'),$text,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllBytes(($evidencePath+'.stderr.bin'),[byte[]]::new(0))
        $streams=[ordered]@{captured=$true}
        foreach($name in @('stdout','stderr')){$path=$evidencePath+".$name.bin";$size=(Get-Item -LiteralPath $path).Length;$streams[$name]=[ordered]@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();size_bytes=$size;drained_bytes=$size;stored_bytes=$size;eof=$true;storage_error=$null;read_error=$null}}
        $status=if($Pass){'passed'}else{'failed'};$code=if($Pass){0}else{9}
        $capture=[ordered]@{Status=$status;ExitCode=$code;Streams=$streams;ChildProcess=[ordered]@{started=$true;outcome=$status;estimated_warning_seconds=60;elapsed_milliseconds=10;cancellation='not-requested';termination_requested=$false;automatic_retry=$false;process_reaped=$true;stdout_eof=$true;stderr_eof=$true;raw_capture_complete=$true;warning_count=0;warning_publication_failures=0;observer_errors=@();exit_code=$code}}
        Write-TestJson ($evidencePath+'.terminal.json') $capture
        $doc=[ordered]@{schema='rusty.morphospace.workflow.current_validation_evidence.v1';project_id=$readerSelector.project.project_id;unit_id=$readerSelector.unit.unit_id;tier='deep';workspace_root=[IO.Path]::GetFullPath($workspace);selection=$readerSelection;project_raw_sha256=$readerSelector.project.spec_raw_sha256;declared_command_sha256=$readerSelector.declared_gate.command_sha256;freeze_receipt_sha256=$readerSelector.candidate_freeze.receipt_sha256;frozen_repositories=@($readerSelector.candidate_freeze.final_repositories);tooling_context=$readerProducer.binding;executor_commit=$readerProducer.context.executor.commit;executor_tree=$readerProducer.context.executor.tree;executed_command=$readerCommand;terminal=[ordered]@{path=$evidencePath+'.terminal.json';sha256=(Get-FileHash -LiteralPath ($evidencePath+'.terminal.json')).Hash.ToLowerInvariant();capture=$capture};result=$(if($Pass){'pass'}else{'fail'});does_not_authorize=@('Modeled typed-reader fixture only; no actual child or authority claim.')}
        Write-TestJson $evidencePath $doc
        return ($doc|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100)
    }
    function Read-ReaderEvidence {&$selectorModule {param($w,$path,$s,$selection,$p)Assert-MorphospaceCurrentValidationEvidence -WorkspaceRoot $w -EvidencePath $path -Selector $s -Selection $selection -ProducerObservation $p} $workspace $evidencePath $readerSelector $readerSelection $readerProducer}
    $readerPass=New-ReaderEvidence $true;Read-ReaderEvidence
    foreach($damage in @('tier','unit','declared-command','frozen-source','context','executed-command','terminal-hash','raw-stdout','raw-stderr','terminal-eof','terminal-reap','terminal-exit','terminal-cancel','terminal-capture','result','success-marker')){
        $doc=New-ReaderEvidence $true
        switch($damage){
            'tier'{$doc.tier='standard'};'unit'{$doc.selection.unit_raw_sha256='0'*64};'declared-command'{$doc.declared_command_sha256='0'*64};'frozen-source'{$doc.frozen_repositories[0].tree='0'*40};'context'{$doc.tooling_context.sha256='0'*64};'executed-command'{$doc.executed_command.arguments[0]='-CallerChoice'};'terminal-hash'{$doc.terminal.sha256='0'*64};'raw-stdout'{[IO.File]::AppendAllText(($evidencePath+'.stdout.bin'),'drift')};'raw-stderr'{[IO.File]::AppendAllText(($evidencePath+'.stderr.bin'),'drift')};'result'{$doc.result='fail'}
            'success-marker'{[IO.File]::WriteAllText(($evidencePath+'.stdout.bin'),'No success marker');$stream=$doc.terminal.capture.Streams.stdout;$stream.sha256=(Get-FileHash -LiteralPath ($evidencePath+'.stdout.bin')).Hash.ToLowerInvariant();$stream.size_bytes=(Get-Item ($evidencePath+'.stdout.bin')).Length;$stream.drained_bytes=$stream.size_bytes;$stream.stored_bytes=$stream.size_bytes}
            default{switch($damage){'terminal-eof'{$doc.terminal.capture.ChildProcess.stdout_eof=$false};'terminal-reap'{$doc.terminal.capture.ChildProcess.process_reaped=$false};'terminal-exit'{$doc.terminal.capture.ExitCode=9;$doc.terminal.capture.ChildProcess.exit_code=9};'terminal-cancel'{$doc.terminal.capture.ChildProcess.termination_requested=$true};'terminal-capture'{$doc.terminal.capture.Streams.captured=$false}}}
        }
        if($damage-like'terminal-*'-and$damage-cne'terminal-hash'-or$damage-ceq'success-marker'){Write-TestJson ($evidencePath+'.terminal.json') $doc.terminal.capture;$doc.terminal.sha256=(Get-FileHash -LiteralPath ($evidencePath+'.terminal.json')).Hash.ToLowerInvariant()}
        Write-TestJson $evidencePath $doc
        Assert-Rejected "typed Deep reader $damage" '*Current validation*' {Read-ReaderEvidence}
    }
    $readerFail=New-ReaderEvidence $false
    Read-ReaderEvidence # A genuine closed nonzero result must remain usable non-PASS evidence.
    $readerGate=[pscustomobject]@{order=1;gate_id='validation-workflow-current';kind='command';profile_id='workflow-current';command=$declaredCommand;disposition='required';selection_kind='exact-external-evidence';selector=[pscustomobject]@{evidence=[pscustomobject]@{path=$evidencePath;sha256=(Get-FileHash -LiteralPath $evidencePath).Hash.ToLowerInvariant();producer_result='fail'}}}
    $badPassReceipt=New-SelectorValidationReceipt -Workspace $workspace -UnitId $unitId -Result pass -Tier deep -MatrixRow $readerGate -EvidencePath $evidencePath -ReceiptLeaf 'deep-failure-cannot-pass.json'
    $readerAutomation=Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -PassThru
    Assert-Rejected 'failed producer cannot satisfy a passing selected gate' '*status differs from its authenticated producer result*' {
        &$readerAutomation {param($w,$u,$spec,$matrix,$path)Test-MorphospaceValidationReceipt -WorkspaceRoot $w -ReceiptReference $path -Spec $spec -Unit $u -RepositoryMap @{} -RepositoryStates @([pscustomobject]@{repo_id='unreached-negative-fixture';available=$true;is_git=$false}) -ValidationMatrix @($matrix) -ExpectedResult pass -ExpectedTier deep} $workspace $readerUnit ([pscustomobject]$project) $readerGate $badPassReceipt
    }
    # Real consumers have other gates after the selected command. The matched
    # row, never the last matrix-loop variable, owns evidence/result checks.
    $roleUnit=$readerUnit|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100
    $roleUnit.validation=@($roleUnit.validation)+@($unit.validation[0])
    $unselectedGate=[pscustomobject]@{order=2;gate_id="validation-$declaredProfile";kind='command';profile_id=$declaredProfile;command=$declaredCommand;disposition='required'}
    $roleReceipt=Get-Content -LiteralPath $badPassReceipt -Raw|ConvertFrom-Json -Depth 100
    $roleReceipt.gates=@($roleReceipt.gates)+@([pscustomobject]@{gate_id=$unselectedGate.gate_id;status='pass';command=$unselectedGate.command;evidence_refs=@([string]$roleReceipt.artifacts[0].artifact_id)})
    $roleReceiptPath=Join-Path $workspace 'receipts/selected-gate-role-damage.json'
    foreach($roleDamage in @('selected-first','selected-last','selected-hash','selected-path')){
        $selectedRole=$readerGate|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100
        $roleMatrix=if($roleDamage-ceq'selected-last'){@($unselectedGate,$selectedRole)}else{@($selectedRole,$unselectedGate)}
        $expectedRoleMessage="*Selected validation gate 'validation-workflow-current' status differs from its authenticated producer result*"
        if($roleDamage-in@('selected-hash','selected-path')){
            $selectedRole.selector.evidence.producer_result='pass'
            if($roleDamage-ceq'selected-hash'){$selectedRole.selector.evidence.sha256='0'*64;$expectedRoleMessage="*Selected validation gate 'validation-workflow-current' external evidence hash drifted*"}
            else{$selectedRole.selector.evidence.path=$projectPath;$expectedRoleMessage="*Selected validation gate 'validation-workflow-current' must reference exactly its bound external evidence artifact*"}
        }
        $roleCaseReceipt=$roleReceipt|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100
        if($roleDamage-ceq'selected-last'){$roleCaseReceipt.gates=@($roleCaseReceipt.gates[1],$roleCaseReceipt.gates[0])}
        Write-TestJson $roleReceiptPath $roleCaseReceipt
        Assert-Rejected "multi-gate exact selected role $roleDamage" $expectedRoleMessage {
            &$readerAutomation {param($w,$u,$spec,$matrix,$path)Test-MorphospaceValidationReceipt -WorkspaceRoot $w -ReceiptReference $path -Spec $spec -Unit $u -RepositoryMap @{} -RepositoryStates @([pscustomobject]@{repo_id='unreached-negative-fixture';available=$true;is_git=$false}) -ValidationMatrix @($matrix) -ExpectedResult pass -ExpectedTier deep} $workspace $roleUnit ([pscustomobject]$project) $roleMatrix $roleReceiptPath
        }
    }
    foreach($suffix in @('','.terminal.json','.stdout.bin','.stderr.bin')){Remove-Item -LiteralPath ($evidencePath+$suffix)}
    # Actual fresh CLI import lifetime, without any selected owner action. A
    # lost Common export must not be mistaken for the intended closed refusal.
    $probeBefore=@($projectPath,$statePath,$eventsPath,$unitPath,$receiptPath|ForEach-Object{(Get-FileHash -LiteralPath $_).Hash})
    $probeCaptureModule=Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceRetainedBuildProcess.psm1') -PassThru
    $probeBase=Join-Path $testRoot 'fresh-producer-refusal'
    $probeEnvironment=@{};foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()){$probeEnvironment[[string]$entry.Key]=[string]$entry.Value}
    $probeExecution=[pscustomobject]@{FileName=(Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'}));WorkingDirectory=$workspace;Arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Invoke-WorkflowCurrentValidation.ps1'),'-WorkspaceRoot',$workspace,'-EvidencePath',($probeBase+'.evidence.json'))}
    $probe=&$probeCaptureModule {param($e,$envValues,$path)Invoke-MorphospaceRetainedBuildProcess -Execution $e -EnvironmentValues $envValues -BaseReceiptPath $path -EstimatedWarningSeconds 60} $probeExecution $probeEnvironment $probeBase
    $probeError=[IO.File]::ReadAllText($probeBase+'.stderr.bin')
    Assert-SelectorTest ($probe.ExitCode-ne0-and$probe.ChildProcess.process_reaped-and$probe.ChildProcess.raw_capture_complete-and$probe.ChildProcess.stdout_eof-and$probe.ChildProcess.stderr_eof) 'fresh producer refusal did not close honestly'
    Assert-SelectorTest ($probeError-like'*Current validation requires an actual selected BeginValidation binding.*'-and$probeError-notlike'*not recognized*') 'fresh producer lost exact module command bindings before its intended guard'
    $probeAfter=@($projectPath,$statePath,$eventsPath,$unitPath,$receiptPath|ForEach-Object{(Get-FileHash -LiteralPath $_).Hash})
    Assert-SelectorTest (($probeBefore-join'|')-ceq($probeAfter-join'|')) 'fresh producer refusal changed fixture owner inputs'
    if($DeclaredTierOnly){[pscustomobject]@{result='pass';declared_tiers=3;tooling_refusals=3;tier_mismatches=3;risk_downgrades=2;schema_damages=18;modeled_deep_reader_damages=16;modeled_nonpass_usable=$true;nonpass_cannot_pass_gate=$true;selected_gate_role_controls=4;fresh_producer_refusal=$true;successful_producer_invoked=$false;child_workflow_validation_dispatched=$false}|ConvertTo-Json -Compress;return}
    Write-TestJson $selectorPath $positiveSelector
    $selectorSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()
    $protectedPaths = @($projectPath, $statePath, $eventsPath, $unitPath, $receiptPath, $producerPath)
    $protectedBefore = @{}
    foreach ($path in $protectedPaths) { $protectedBefore[$path] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }

    $ordinary = Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -Timestamp $fixed
    $ordinaryRow = @($ordinary.validation_matrix | Where-Object { $_.profile_id -ceq $declaredProfile })
    Assert-SelectorTest ($ordinaryRow.Count -eq 1 -and [string]$ordinaryRow[0].command -ceq $declaredCommand -and -not ($ordinaryRow[0].PSObject.Properties.Name -contains 'selector')) 'selector absence changed ordinary Unit.validation behavior'

    $selected = Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick `
        -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath -Timestamp $fixed
    $selectedRow = @($selected.validation_matrix | Where-Object { $_.profile_id -ceq $declaredProfile })
    Assert-SelectorTest ($selected.transition -ceq 'validation-selector-bound' -and -not $selected.executed) 'selector dispatch dry-run did not expose the pending exact binding without execution'
    Assert-SelectorTest ($selectedRow.Count -eq 1 -and [string]$selectedRow[0].selection_kind -ceq 'exact-external-evidence') 'selector did not replace exactly one declared gate'
    Assert-SelectorTest ([string]$selectedRow[0].gate_id -ceq "validation-$declaredProfile" -and [string]$selectedRow[0].profile_id -ceq $declaredProfile) 'selector changed the immutable declared gate identity'
    Assert-SelectorTest ([string]$selectedRow[0].selector.sha256 -ceq $selectorSha256 -and [string]$selectedRow[0].selector.producer_sha256 -ceq [string]$positiveSelector.selection.producer.sha256) 'selector or producer identity was not exposed'
    Assert-SelectorTest ([string]$selectedRow[0].selector.evidence.path -ceq [IO.Path]::GetFullPath($evidencePath) -and [string]$selectedRow[0].selector.evidence.schema -ceq [string]$positiveSelector.selection.output_evidence.schema) 'output evidence identity was not exposed'
    Assert-SelectorTest ([string]$selectedRow[0].command -match 'Test-UnitSelector003Quick\.ps1' -and [string]$selectedRow[0].command -match [regex]::Escape($evidenceName)) 'consumer did not synthesize the fixed producer command'
    Assert-SelectorTest (-not (Test-Path -LiteralPath $evidencePath)) 'consumer executed the producer or created evidence'

    Assert-Rejected 'missing selector bindings' '*requires ExpectedValidationSelectorSha256 and ValidationEvidencePath*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative
    }
    Assert-Rejected 'orphaned evidence path' '*invalid without ValidationSelector*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationEvidencePath $evidencePath
    }
    Assert-Rejected 'selector hash mismatch' '*SHA-256 does not match*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 ('0' * 64) -ValidationEvidencePath $evidencePath
    }
    Assert-Rejected 'non-Quick selector use' '*valid only for the Quick tier*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier standard -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath
    }
    Assert-Rejected 'unrelated action selector use' '*valid only for BeginValidation or a receipt-consuming validation lifecycle action*' {
        Invoke-MorphospaceWorkUnitAutomation -Action Inspect -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath
    }
    Assert-Rejected 'selector outside authority directory' '*must be exact files under validation-authority/selectors*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector 'tools/selector.json' -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath
    }
    $alternateEvidenceRoot = Join-Path $testRoot 'alternate-evidence'
    [IO.Directory]::CreateDirectory($alternateEvidenceRoot) | Out-Null
    Assert-Rejected 'same evidence leaf under a different parent' '*canonical path does not match the exact selector binding*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath (Join-Path $alternateEvidenceRoot $evidenceName)
    }

    $aliasRelative = 'validation-authority/selectors/unit-selector-003-quick-alias.json'
    $aliasPath = Join-Path $workspace ($aliasRelative -replace '/', '\')
    Write-TestJson $aliasPath $positiveSelector
    $aliasSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $aliasPath).Hash.ToLowerInvariant()
    Assert-Rejected 'duplicate selector identity under an alias leaf' '*file leaf must exactly equal selector_id*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $aliasRelative -ExpectedValidationSelectorSha256 $aliasSha -ValidationEvidencePath $evidencePath
    }
    Remove-Item -LiteralPath $aliasPath -Force

    $aliasedSelector = New-SelectorDocument
    $aliasedSelector.selector_id = 'unit-selector-003-other-id'
    Write-TestJson $selectorPath $aliasedSelector
    $aliasedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()
    Assert-Rejected 'selector ID differs from canonical file leaf' '*file leaf must exactly equal selector_id*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $aliasedSha -ValidationEvidencePath $evidencePath
    }
    Write-TestJson $selectorPath $positiveSelector
    $selectorSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()

    $projectBytes = [IO.File]::ReadAllBytes($projectPath)
    try {
        [IO.File]::AppendAllText($projectPath, ' ', [Text.UTF8Encoding]::new($false))
        Assert-Rejected 'project raw drift' '*project identity or raw bytes drifted*' {
            Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath
        }
    } finally { [IO.File]::WriteAllBytes($projectPath, $projectBytes) }

    $unitBytes = [IO.File]::ReadAllBytes($unitPath)
    try {
        [IO.File]::AppendAllText($unitPath, ' ', [Text.UTF8Encoding]::new($false))
        Assert-Rejected 'unit raw drift' '*unit raw bytes drifted*' {
            Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath
        }
    } finally { [IO.File]::WriteAllBytes($unitPath, $unitBytes) }

    $receiptBytes = [IO.File]::ReadAllBytes($receiptPath)
    try {
        [IO.File]::AppendAllText($receiptPath, ' ', [Text.UTF8Encoding]::new($false))
        Assert-Rejected 'freeze receipt drift' '*candidate-freeze receipt bytes drifted*' {
            Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath
        }
    } finally { [IO.File]::WriteAllBytes($receiptPath, $receiptBytes) }

    $producerBytes = [IO.File]::ReadAllBytes($producerPath)
    try {
        [IO.File]::AppendAllText($producerPath, ' ', [Text.UTF8Encoding]::new($false))
        Assert-Rejected 'producer drift' '*evidence producer bytes drifted*' {
            Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath
        }
    } finally { [IO.File]::WriteAllBytes($producerPath, $producerBytes) }

    $damagedSelector = New-SelectorDocument
    $damagedSelector.declared_gate.command_sha256 = '3' * 64
    Write-TestJson $selectorPath $damagedSelector
    $damagedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()
    Assert-Rejected 'declared gate drift' '*declared gate command binding drifted*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $damagedSha -ValidationEvidencePath $evidencePath
    }

    $damagedSelector = New-SelectorDocument
    $damagedSelector.candidate_freeze.final_repositories[0].tree = '4' * 40
    Write-TestJson $selectorPath $damagedSelector
    $damagedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()
    Assert-Rejected 'frozen repository drift' '*frozen candidate repository binding drifted*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $damagedSha -ValidationEvidencePath $evidencePath
    }

    $damagedSelector = New-SelectorDocument
    $damagedSelector | Add-Member -NotePropertyName command -NotePropertyValue 'pwsh -File arbitrary.ps1'
    Write-TestJson $selectorPath $damagedSelector
    $damagedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()
    Assert-Rejected 'arbitrary selector command' '*does not satisfy normal-validation-selector-v1.schema.json*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $damagedSha -ValidationEvidencePath $evidencePath
    }

    Write-TestJson $selectorPath $positiveSelector
    $selectorSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()
    Assert-Rejected 'evidence leaf mismatch' '*file name does not match*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath (Join-Path $evidenceRoot 'different.json')
    }
    [IO.File]::WriteAllText($evidencePath, 'pre-existing', [Text.UTF8Encoding]::new($false))
    $collisionSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $evidencePath).Hash.ToLowerInvariant()
    Assert-Rejected 'evidence collision' '*evidence collision; refusing to dispatch*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath
    }
    Assert-SelectorTest ((Get-FileHash -Algorithm SHA256 -LiteralPath $evidencePath).Hash.ToLowerInvariant() -ceq $collisionSha) 'evidence collision changed existing bytes'
    Remove-Item -LiteralPath $evidencePath -Force

    foreach ($path in $protectedPaths) {
        Assert-SelectorTest ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -ceq $protectedBefore[$path]) "protected fixture bytes changed: $path"
    }
    Assert-SelectorTest (-not (Test-Path -LiteralPath $evidencePath)) 'test left selected evidence behind'

    $boundDispatch = Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick `
        -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath -Timestamp $fixed -Execute
    $boundState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    Assert-SelectorTest ($boundDispatch.transition -ceq 'validation-selector-bound' -and $boundDispatch.executed) 'executed BeginValidation did not bind the selector to an already-validating unit'
    Assert-SelectorTest (
        [string]$boundState.normal_validation_selection.selector_id -ceq $selectorId -and
        [string]$boundState.normal_validation_selection.selector_sha256 -ceq $selectorSha256 -and
        [string]$boundState.normal_validation_selection.unit_raw_sha256 -ceq [string]$positiveSelector.unit.raw_sha256 -and
        [string]$boundState.normal_validation_selection.unit_contract_sha256 -ceq [string]$positiveSelector.unit.contract_sha256 -and
        [string]$boundState.normal_validation_selection.evidence_path_sha256 -ceq (Get-TestCanonicalPathSha256 $evidencePath) -and
        -not ($boundState.normal_validation_selection.PSObject.Properties.Name -contains 'command')
    ) 'workspace state did not retain only the exact hash-bound selector/evidence identity'

    Assert-Rejected 'receipt consumption before evidence exists' '*evidence is required for receipt consumption*' {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/missing.json' `
            -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath -Timestamp $fixed
    }
    Assert-Rejected 'selector omission at RecordValidation' '*requires the exact normal-validation selector and evidence path bound in workspace state*' {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/missing.json' -Timestamp $fixed
    }

    $evidenceDocument = [ordered]@{
        schema = 'rusty.morphospace.test.unit003.quick-evidence.v1'
        unit_id = $unitId
        result = 'fail'
        legacy_files_read = 0
    }
    Write-TestCreateNewJson $evidencePath $evidenceDocument
    $evidenceBytes = [IO.File]::ReadAllBytes($evidencePath)

    Assert-Rejected 'receipt evidence path substitution' '*canonical path does not match the exact selector binding*' {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/missing.json' `
            -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath (Join-Path $alternateEvidenceRoot $evidenceName) -Timestamp $fixed
    }

    $selectorDrift = New-SelectorDocument
    $selectorDrift.does_not_authorize = @($selectorDrift.does_not_authorize) + 'Changed after dispatch.'
    Write-TestJson $selectorPath $selectorDrift
    $selectorDriftSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()
    Assert-Rejected 'selector drift between dispatch and receipt consumption' '*does not match the exact binding established by BeginValidation*' {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/missing.json' `
            -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorDriftSha -ValidationEvidencePath $evidencePath -Timestamp $fixed
    }
    Write-TestJson $selectorPath $positiveSelector
    $selectorSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()

    $wrongSchemaBytes = [IO.File]::ReadAllBytes($evidencePath)
    Write-TestJson $evidencePath ([ordered]@{ schema = 'rusty.morphospace.test.wrong-evidence.v1'; unit_id = $unitId })
    Assert-Rejected 'selected evidence schema drift' '*evidence schema does not match the exact selector binding*' {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/missing.json' `
            -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath -Timestamp $fixed
    }
    [IO.File]::WriteAllBytes($evidencePath, $wrongSchemaBytes)

    $failedReceiptPath = New-SelectorValidationReceipt -Workspace $workspace -UnitId $unitId -Result fail -MatrixRow $boundDispatch.validation_matrix[0] -EvidencePath $evidencePath -ReceiptLeaf 'unit-selector-003-fail-validation.json'
    [IO.File]::AppendAllText($evidencePath, ' ', [Text.UTF8Encoding]::new($false))
    Assert-Rejected 'selected evidence bytes drift before receipt consumption' '*Validation artifact hash mismatch*' {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/unit-selector-003-fail-validation.json' `
            -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath -Timestamp $fixed
    }
    [IO.File]::WriteAllBytes($evidencePath, $evidenceBytes)

    $nonPassingRecord = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/unit-selector-003-fail-validation.json' `
        -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath -Timestamp $fixed
    Assert-SelectorTest ($nonPassingRecord.transition -ceq 'validation-fail' -and -not $nonPassingRecord.executed) 'non-passing RecordValidation did not consume the exact selected matrix'

    $terminalProjectRoot = Join-Path $testRoot 'terminal-project'
    $terminalWorkspace = Join-Path $terminalProjectRoot 'morphospace'
    $terminalRepoMapPath = Join-Path $terminalProjectRoot 'repository-map.json'
    $terminalMappedRepoRoot = Join-Path $testRoot 'terminal-mapped-repository'
    $terminalTrackedPath = Join-Path $terminalMappedRepoRoot 'morphospace\tracked-input.txt'
    [IO.Directory]::CreateDirectory($terminalProjectRoot) | Out-Null
    [IO.Directory]::CreateDirectory((Split-Path -Parent $terminalTrackedPath)) | Out-Null
    [IO.File]::WriteAllText($terminalTrackedPath, "terminal repository baseline`n", [Text.UTF8Encoding]::new($false))
    Invoke-TestGit -RepositoryPath $terminalMappedRepoRoot -Arguments @('init', '--quiet') | Out-Null
    Invoke-TestGit -RepositoryPath $terminalMappedRepoRoot -Arguments @('branch', '-M', 'main') | Out-Null
    Invoke-TestGit -RepositoryPath $terminalMappedRepoRoot -Arguments @('add', '--', 'morphospace/tracked-input.txt') | Out-Null
    Invoke-TestGit -RepositoryPath $terminalMappedRepoRoot -Arguments @('-c', 'user.name=Morphospace Test', '-c', 'user.email=morphospace-test@example.invalid', 'commit', '--quiet', '-m', 'Create terminal selector fixture') | Out-Null
    $terminalRepoHead = Invoke-TestGit -RepositoryPath $terminalMappedRepoRoot -Arguments @('rev-parse', 'HEAD')
    $terminalRepositoryRevision = [ordered]@{
        repo_id = 'project-shell'
        branch = 'main'
        base_revision = $terminalRepoHead
        head_revision = $terminalRepoHead
    }
    Copy-Item -LiteralPath $workspace -Destination $terminalWorkspace -Recurse
    Write-TestJson $terminalRepoMapPath ([ordered]@{
        schema = 'rusty.morphospace.workflow.repository_map.v1'
        repositories = @([ordered]@{ repo_id = 'project-shell'; path = $terminalMappedRepoRoot; role = 'planning' })
    })
    $terminalStatePath = Join-Path $terminalWorkspace 'workspace.state.json'
    $terminalUnitPath = Join-Path $terminalWorkspace ($unitRelative -replace '/', '\')
    $terminalSelection = (Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json).normal_validation_selection
    $terminalMatrixRow = $boundDispatch.validation_matrix[0] | Select-Object *
    $terminalMatrixRow.command = ([string]$terminalMatrixRow.command).Replace(
        [IO.Path]::GetFullPath($workspace),
        [IO.Path]::GetFullPath($terminalWorkspace),
        [StringComparison]::OrdinalIgnoreCase
    )
    New-SelectorValidationReceipt -Workspace $terminalWorkspace -UnitId $unitId -Result fail -MatrixRow $terminalMatrixRow -EvidencePath $evidencePath -ReceiptLeaf 'unit-selector-003-fail-validation.json' -RepositoryRevision $terminalRepositoryRevision | Out-Null
    $terminalRecord = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $terminalWorkspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/unit-selector-003-fail-validation.json' `
        -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath -Timestamp $fixed -Execute
    $terminalState = Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json
    $terminalUnit = Get-Content -Raw -LiteralPath $terminalUnitPath | ConvertFrom-Json
    Assert-SelectorTest (
        $terminalRecord.transition -ceq 'validation-fail' -and
        $terminalRecord.executed -and
        [string]$terminalUnit.status -ceq 'blocked' -and
        $null -eq $terminalState.current_unit -and
        $null -eq $terminalState.normal_validation_selection
    ) 'executed non-passing RecordValidation did not terminally clear the consumed selector binding'

    $successorId = 'unit-selector-004'
    $successorPath = Join-Path $terminalWorkspace "iteration-units\$successorId.json"
    $successor = Get-Content -Raw -LiteralPath $terminalUnitPath | ConvertFrom-Json
    $successor.unit_id = $successorId
    $successor.status = 'proposed'
    # The new requested declaration uses a registered category. Retained
    # terminal fixture declarations keep their original historical bytes.
    $successor.change_categories = @('implementation')
    $successor.objective = 'Prove exact recovery of a historical terminal selector binding.'
    if ($successor.PSObject.Properties.Name -contains 'candidate_freeze') {
        $successor.PSObject.Properties.Remove('candidate_freeze')
    }
    Write-TestJson $successorPath $successor

    # Recreate only the exact stale state produced by the prior consumer: the old
    # unit is blocked and its checkpoint/blocker are terminal, but its selector
    # binding was not cleared.
    $terminalState.normal_validation_selection = $terminalSelection
    Write-TestJson $terminalStatePath $terminalState
    $terminalEventsPath = Join-Path $terminalWorkspace 'iteration-events.jsonl'
    $terminalEvent = Get-Content -LiteralPath $terminalEventsPath | Select-Object -Last 1 | ConvertFrom-Json -DateKind String
    $terminalTransactionId = "$([string]$terminalEvent.event_id)-transition"
    $terminalIntentPath = Join-Path $terminalWorkspace "receipts/transactions/$terminalTransactionId.intent.json"
    $terminalCompletionPath = Join-Path $terminalWorkspace "receipts/transactions/$terminalTransactionId.completion.json"
    $terminalIntent = Read-MorphospaceProtocolJson -Path $terminalIntentPath
    $terminalCompletion = Read-MorphospaceProtocolJson -Path $terminalCompletionPath
    $terminalStateSha256 = Get-MorphospaceCanonicalJsonSha256 $terminalState
    $terminalUnitSha256 = Get-MorphospaceCanonicalJsonSha256 $terminalUnit
    $terminalIntent.target.state.document = $terminalState
    $terminalIntent.target.state.sha256 = $terminalStateSha256
    $terminalIntent.target.unit.document = $terminalUnit
    $terminalIntent.target.unit.sha256 = $terminalUnitSha256
    Write-TestJson $terminalIntentPath $terminalIntent
    $terminalCompletion.state_sha256 = $terminalStateSha256
    $terminalCompletion.unit_sha256 = $terminalUnitSha256
    $terminalCompletion.intent.sha256 = (Get-FileHash -LiteralPath $terminalIntentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-TestJson $terminalCompletionPath $terminalCompletion
    $terminalEventsBytes = [IO.File]::ReadAllBytes($terminalEventsPath)
    $terminalIntentBytes = [IO.File]::ReadAllBytes($terminalIntentPath)
    $terminalCompletionBytes = [IO.File]::ReadAllBytes($terminalCompletionPath)
    Assert-Rejected 'terminal selector release on a non-Ready action' '*normal-validation selection for a different unit*' {
        Invoke-MorphospaceWorkUnitAutomation -Action Claim -WorkspaceRoot $terminalWorkspace -UnitId $successorId -Timestamp $fixed
    }

    $terminalStateBytes = [IO.File]::ReadAllBytes($terminalStatePath)
    try {
        $damagedTerminalState = Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json
        $damagedTerminalState.validation_checkpoint.result = 'pass'
        Write-TestJson $terminalStatePath $damagedTerminalState
        Assert-Rejected 'terminal selector release with a nonterminal checkpoint' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalStatePath, $terminalStateBytes) }

    try {
        $damagedTerminalState = Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json
        $damagedTerminalState.validation_checkpoint.tier = 'standard'
        Write-TestJson $terminalStatePath $damagedTerminalState
        Assert-Rejected 'terminal selector release with checkpoint tier drift' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalStatePath, $terminalStateBytes) }

    try {
        $laterEvent = (($terminalEvent | ConvertTo-Json -Depth 32) | ConvertFrom-Json -DateKind String)
        $laterEvent.event_id = "$unitId-unrelated-checkpoint-0003"
        $laterEvent.sequence = [int]$laterEvent.sequence + 1
        $laterEvent.event_type = 'checkpoint'
        $laterEvent.summary = 'Unrelated later event used to prove physical-tail binding.'
        $laterEvent.receipts = @()
        $laterLine = ($laterEvent | ConvertTo-Json -Depth 32 -Compress) + "`n"
        $laterBytes = [Text.UTF8Encoding]::new($false).GetBytes($laterLine)
        $damagedEvents = [byte[]]::new($terminalEventsBytes.Length + $laterBytes.Length)
        [Array]::Copy($terminalEventsBytes, 0, $damagedEvents, 0, $terminalEventsBytes.Length)
        [Array]::Copy($laterBytes, 0, $damagedEvents, $terminalEventsBytes.Length, $laterBytes.Length)
        [IO.File]::WriteAllBytes($terminalEventsPath, $damagedEvents)
        Assert-Rejected 'terminal selector release when the blocker is not the physical ledger tail' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalEventsPath, $terminalEventsBytes) }

    foreach ($intentDamage in @(
        [pscustomobject]@{ name = 'event-schema'; apply = { param($value) $value.event.schema = 'rusty.morphospace.workflow.iteration_event.v9' } },
        [pscustomobject]@{ name = 'event-timestamp'; apply = { param($value) $value.event.timestamp = 'not-a-timestamp' } },
        [pscustomobject]@{ name = 'extra-root-property'; apply = { param($value) $value | Add-Member -NotePropertyName unauthorized -NotePropertyValue $true } },
        [pscustomobject]@{ name = 'state-path'; apply = { param($value) $value.state.path = 'receipts/substituted-state.json' } }
    )) {
        try {
            $damagedIntent = Read-MorphospaceProtocolJson -Path $terminalIntentPath
            & $intentDamage.apply $damagedIntent
            Write-TestJson $terminalIntentPath $damagedIntent
            $damagedCompletion = Read-MorphospaceProtocolJson -Path $terminalCompletionPath
            $damagedCompletion.intent.sha256 = (Get-FileHash -LiteralPath $terminalIntentPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-TestJson $terminalCompletionPath $damagedCompletion
            Assert-Rejected "terminal selector release with $([string]$intentDamage.name) intent damage" '*normal-validation selection for a different unit*' {
                Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
            }
        } finally {
            [IO.File]::WriteAllBytes($terminalIntentPath, $terminalIntentBytes)
            [IO.File]::WriteAllBytes($terminalCompletionPath, $terminalCompletionBytes)
        }
    }

    $shadowStateRelative = 'receipts/shadow-workspace.state.json'
    $shadowUnitRelative = 'receipts/shadow-terminal-unit.json'
    $shadowEventsRelative = 'receipts/shadow-iteration-events.jsonl'
    $shadowStatePath = Join-Path $terminalWorkspace ($shadowStateRelative -replace '/', '\')
    $shadowUnitPath = Join-Path $terminalWorkspace ($shadowUnitRelative -replace '/', '\')
    $shadowEventsPath = Join-Path $terminalWorkspace ($shadowEventsRelative -replace '/', '\')
    [IO.File]::WriteAllBytes($shadowStatePath, $terminalStateBytes)
    [IO.File]::WriteAllBytes($shadowUnitPath, [IO.File]::ReadAllBytes($terminalUnitPath))
    [IO.File]::WriteAllBytes($shadowEventsPath, $terminalEventsBytes)
    try {
        $shadowIntent = Read-MorphospaceProtocolJson -Path $terminalIntentPath
        $shadowIntent.state.path = $shadowStateRelative
        $shadowIntent.unit.path = $shadowUnitRelative
        $shadowIntent.events.path = $shadowEventsRelative
        Write-TestJson $terminalIntentPath $shadowIntent
        $shadowCompletion = Read-MorphospaceProtocolJson -Path $terminalCompletionPath
        $shadowCompletion.intent.sha256 = (Get-FileHash -LiteralPath $terminalIntentPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-TestJson $terminalCompletionPath $shadowCompletion
        Assert-Rejected 'terminal selector release through internally consistent shadow workspace paths' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally {
        [IO.File]::WriteAllBytes($terminalIntentPath, $terminalIntentBytes)
        [IO.File]::WriteAllBytes($terminalCompletionPath, $terminalCompletionBytes)
    }

    foreach ($completionDamage in @(
        [pscustomobject]@{ name = 'intent-role'; apply = { param($value) $value.intent.role = 'substituted-intent' } },
        [pscustomobject]@{ name = 'intent-schema'; apply = { param($value) $value.intent.schema = 'rusty.morphospace.workflow.transition_ledger_intent.v9' } },
        [pscustomobject]@{ name = 'extra-root-property'; apply = { param($value) $value | Add-Member -NotePropertyName unauthorized -NotePropertyValue $true } }
    )) {
        try {
            $damagedCompletion = Read-MorphospaceProtocolJson -Path $terminalCompletionPath
            & $completionDamage.apply $damagedCompletion
            Write-TestJson $terminalCompletionPath $damagedCompletion
            Assert-Rejected "terminal selector release with $([string]$completionDamage.name) completion damage" '*normal-validation selection for a different unit*' {
                Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
            }
        } finally { [IO.File]::WriteAllBytes($terminalCompletionPath, $terminalCompletionBytes) }
    }

    try {
        $damagedTerminalState = Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json
        $damagedTerminalState.normal_validation_selection.unit_contract_sha256 = '0' * 64
        Write-TestJson $terminalStatePath $damagedTerminalState
        Assert-Rejected 'terminal selector release with unit-contract drift' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalStatePath, $terminalStateBytes) }

    try {
        $damagedTerminalState = Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json
        $damagedTerminalState.blockers[0].resume_when = 'Damaged recovery condition.'
        Write-TestJson $terminalStatePath $damagedTerminalState
        Assert-Rejected 'terminal selector release with blocker drift' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalStatePath, $terminalStateBytes) }

    try {
        $damagedTerminalState = Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json
        $damagedTerminalState.blockers = @($damagedTerminalState.blockers) + (($damagedTerminalState.blockers[0] | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
        Write-TestJson $terminalStatePath $damagedTerminalState
        Assert-Rejected 'terminal selector release with a duplicate blocker ID' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalStatePath, $terminalStateBytes) }

    $terminalReceiptPath = Join-Path $terminalWorkspace 'receipts/unit-selector-003-fail-validation.json'
    $terminalReceiptBytes = [IO.File]::ReadAllBytes($terminalReceiptPath)
    try {
        $damagedTerminalReceipt = Get-Content -Raw -LiteralPath $terminalReceiptPath | ConvertFrom-Json
        $damagedTerminalReceipt.unit_id = $successorId
        Write-TestJson $terminalReceiptPath $damagedTerminalReceipt
        Assert-Rejected 'terminal selector release with a foreign validation receipt' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalReceiptPath, $terminalReceiptBytes) }

    try {
        $damagedTerminalReceipt = Get-Content -Raw -LiteralPath $terminalReceiptPath | ConvertFrom-Json
        $damagedTerminalReceipt.schema = 'rusty.morphospace.workflow.validation_receipt.v9'
        Write-TestJson $terminalReceiptPath $damagedTerminalReceipt
        Assert-Rejected 'terminal selector release with unsupported validation receipt schema' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalReceiptPath, $terminalReceiptBytes) }

    $terminalUnitBytes = [IO.File]::ReadAllBytes($terminalUnitPath)
    try {
        $damagedTerminalUnit = Get-Content -Raw -LiteralPath $terminalUnitPath | ConvertFrom-Json
        $damagedTerminalUnit.status = 'active'
        Write-TestJson $terminalUnitPath $damagedTerminalUnit
        Assert-Rejected 'terminal selector release with a nonblocked selected unit' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalUnitPath, $terminalUnitBytes) }

    $successorBytes = [IO.File]::ReadAllBytes($successorPath)
    try {
        $damagedSuccessor = Get-Content -Raw -LiteralPath $successorPath | ConvertFrom-Json
        $damagedSuccessor.status = 'ready'
        Write-TestJson $successorPath $damagedSuccessor
        Assert-Rejected 'terminal selector release to an already-ready successor' '*normal-validation selection for a different unit*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($successorPath, $successorBytes) }

    Assert-Rejected 'terminal selector release without complete repository mappings' '*complete repository mappings*' {
        Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -Timestamp $fixed
    }
    $unavailableRepoMapPath = Join-Path $terminalProjectRoot 'repository-map-unavailable.json'
    Write-TestJson $unavailableRepoMapPath ([ordered]@{
        schema = 'rusty.morphospace.workflow.repository_map.v1'
        repositories = @([ordered]@{ repo_id = 'project-shell'; path = (Join-Path $terminalProjectRoot 'missing-project-shell'); role = 'planning' })
    })
    Assert-Rejected 'terminal selector release with unavailable repository mapping' '*normal-validation selection for a different unit*' {
        Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $unavailableRepoMapPath -Timestamp $fixed
    }
    $terminalTrackedBytes = [IO.File]::ReadAllBytes($terminalTrackedPath)
    try {
        [IO.File]::AppendAllText($terminalTrackedPath, "tracked drift`n", [Text.UTF8Encoding]::new($false))
        Assert-Rejected 'terminal selector release with tracked repository drift' '*exact clean Git repository observations*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally { [IO.File]::WriteAllBytes($terminalTrackedPath, $terminalTrackedBytes) }
    $terminalUntrackedPath = Join-Path $terminalMappedRepoRoot 'morphospace\untracked-input.txt'
    try {
        [IO.File]::WriteAllText($terminalUntrackedPath, "untracked drift`n", [Text.UTF8Encoding]::new($false))
        Assert-Rejected 'terminal selector release with untracked repository drift' '*exact clean Git repository observations*' {
            Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
        }
    } finally {
        if ([IO.File]::Exists($terminalUntrackedPath)) { [IO.File]::Delete($terminalUntrackedPath) }
    }
    $automationModule = Get-Module WorkUnitAutomation
    $legacyReleaseRoute = & $automationModule {
        param($arguments)
        Get-MorphospaceReadyTerminalReleaseRoute @arguments
    } @{
        WorkspaceRoot = $terminalWorkspace
        UnitId = $successorId
        Events = @(Get-Content -LiteralPath $terminalEventsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
    }
    Assert-SelectorTest ([string]$legacyReleaseRoute -ceq 'legacy-v1') 'ordinary stale-selector Ready was routed through blocked-successor release-v2'

    $ordinaryReadyWorkspace = Join-Path $testRoot 'ordinary-ready-no-selector'
    Copy-Item -LiteralPath $terminalWorkspace -Destination $ordinaryReadyWorkspace -Recurse
    $ordinaryReadyStatePath = Join-Path $ordinaryReadyWorkspace 'workspace.state.json'
    $ordinaryReadyState = Get-Content -Raw -LiteralPath $ordinaryReadyStatePath | ConvertFrom-Json -DateKind String
    $ordinaryReadyState.normal_validation_selection = $null
    Write-TestJson $ordinaryReadyStatePath $ordinaryReadyState
    $ordinaryReady = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $ordinaryReadyWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
    Assert-SelectorTest (
        [string]$ordinaryReady.transition -ceq 'proposed-to-ready' -and
        $null -eq $ordinaryReady.terminal_validation_selection_release
    ) 'ordinary no-selector Ready evaluated or emitted a terminal release provider'

    $terminalReadyDryRun = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed
    $automationReceiptSchemaPath = Join-Path $repoRoot 'schemas\work-unit-automation-receipt.schema.json'
    $terminalReleaseSchemaPath = Join-Path $repoRoot 'schemas\terminal-validation-selection-release-v1.schema.json'
    Assert-SelectorTest (
        Test-Json -Json ($terminalReadyDryRun | ConvertTo-Json -Depth 100) -SchemaFile $automationReceiptSchemaPath
    ) 'terminal selector recovery dry-run receipt failed its public schema'
    $terminalStateAfterDryRun = Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json
    $terminalReleaseReference = "receipts/$successorId-terminal-validation-selection-release.json"
    $terminalReleasePath = Join-Path $terminalWorkspace ($terminalReleaseReference -replace '/', '\')
    Assert-SelectorTest (
        $terminalReadyDryRun.transition -ceq 'proposed-to-ready' -and
        -not $terminalReadyDryRun.executed -and
        $null -ne $terminalStateAfterDryRun.normal_validation_selection -and
        $null -ne $terminalReadyDryRun.terminal_validation_selection_release -and
        [string]$terminalReadyDryRun.terminal_validation_selection_release.path -ceq $terminalReleaseReference -and
        [string]$terminalReadyDryRun.terminal_validation_selection_release.terminal_unit_id -ceq $unitId -and
        -not [IO.File]::Exists($terminalReleasePath)
    ) 'terminal selector recovery dry run changed state or failed to plan Ready'
    $terminalReady = Invoke-MorphospaceWorkUnitAutomation -Action Ready -WorkspaceRoot $terminalWorkspace -UnitId $successorId -RepoMapPath $terminalRepoMapPath -Timestamp $fixed -Execute
    $terminalStateAfterReady = Get-Content -Raw -LiteralPath $terminalStatePath | ConvertFrom-Json
    $terminalReleaseProof = Read-MorphospaceProtocolJson -Path $terminalReleasePath
    Assert-SelectorTest (
        Test-Json -Json ($terminalReady | ConvertTo-Json -Depth 100) -SchemaFile $automationReceiptSchemaPath
    ) 'executed terminal selector recovery receipt failed its public schema'
    Assert-SelectorTest (
        Test-Json -Json ($terminalReleaseProof | ConvertTo-Json -Depth 100) -SchemaFile $terminalReleaseSchemaPath
    ) 'terminal selector release proof failed its public schema'
    $terminalReleaseSha256 = (Get-FileHash -LiteralPath $terminalReleasePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $readyEvent = Get-Content -LiteralPath $terminalEventsPath | Select-Object -Last 1 | ConvertFrom-Json -DateKind String
    $readyIntentPath = Join-Path $terminalWorkspace "receipts/transactions/$([string]$readyEvent.event_id)-transition.intent.json"
    $readyIntent = Read-MorphospaceProtocolJson -Path $readyIntentPath
    $readyProofArtifacts = @($readyIntent.artifacts | Where-Object {
        [string]$_.path -ceq $terminalReleaseReference -and [string]$_.sha256 -ceq $terminalReleaseSha256
    })
    Assert-SelectorTest (
        $terminalReady.transition -ceq 'proposed-to-ready' -and
        $terminalReady.executed -and
        $null -eq $terminalStateAfterReady.normal_validation_selection -and
        [string]$terminalReady.terminal_validation_selection_release.sha256 -ceq $terminalReleaseSha256 -and
        [string]$terminalReleaseProof.schema -ceq 'rusty.morphospace.workflow.terminal_validation_selection_release.v1' -and
        [string]$terminalReleaseProof.terminal.checkpoint.receipt_sha256 -ceq ((Get-FileHash -LiteralPath $terminalReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()) -and
        [string]$terminalReleaseProof.terminal.evidence.sha256 -ceq ((Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()) -and
        [string]$terminalReleaseProof.terminal.transaction.intent_sha256 -ceq ((Get-FileHash -LiteralPath $terminalIntentPath -Algorithm SHA256).Hash.ToLowerInvariant()) -and
        [string]$terminalReleaseProof.terminal.transaction.completion_sha256 -ceq ((Get-FileHash -LiteralPath $terminalCompletionPath -Algorithm SHA256).Hash.ToLowerInvariant()) -and
        @($terminalReleaseProof.terminal.repositories).Count -eq 1 -and
        [bool]$terminalReleaseProof.terminal.repositories[0].is_git -and
        -not [bool]$terminalReleaseProof.terminal.repositories[0].dirty -and
        [string]$terminalReleaseProof.terminal.repositories[0].dirty_fingerprint -ceq (Get-TestTextSha256 '') -and
        @($readyEvent.receipts).Count -eq 1 -and [string]$readyEvent.receipts[0] -ceq $terminalReleaseReference -and
        $readyProofArtifacts.Count -eq 1
    ) 'executed Ready did not transactionally clear the exact historical terminal selector binding'

    Assert-Rejected 'selector omission at ReturnToActive' '*requires the exact normal-validation selector and evidence path bound in workspace state*' {
        Invoke-MorphospaceWorkUnitAutomation -Action ReturnToActive -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/unit-selector-003-fail-validation.json' -Timestamp $fixed
    }
    $returned = Invoke-MorphospaceWorkUnitAutomation -Action ReturnToActive -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult fail -ValidationReceipt 'receipts/unit-selector-003-fail-validation.json' `
        -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $selectorSha256 -ValidationEvidencePath $evidencePath -Timestamp $fixed -Execute
    Assert-SelectorTest ($returned.transition -ceq 'validation-fail-to-active' -and $returned.status_after -ceq 'active') 'ReturnToActive did not retain the selected non-passing attempt'

    $replaySelector = New-SelectorDocument
    Write-TestJson $selectorPath $replaySelector
    $replaySelectorSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectorPath).Hash.ToLowerInvariant()
    Assert-Rejected 'selected evidence replay collision' '*evidence collision; refusing to dispatch*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick `
            -ValidationSelector $selectorRelative -ExpectedValidationSelectorSha256 $replaySelectorSha -ValidationEvidencePath $evidencePath -Timestamp $fixed
    }
    Assert-Rejected 'selector omission on a new attempt' '*requires the exact normal-validation selector and evidence path bound in workspace state*' {
        Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -Timestamp $fixed
    }

    $retrySelectorId = 'unit-selector-003-quick-retry'
    $retrySelectorRelative = "validation-authority/selectors/$retrySelectorId.json"
    $retrySelectorPath = Join-Path $workspace ($retrySelectorRelative -replace '/', '\')
    $retryEvidenceName = 'unit-selector-003-quick-evidence-retry.json'
    $retryEvidencePath = Join-Path $evidenceRoot $retryEvidenceName
    $retrySelector = New-SelectorDocument -DocumentSelectorId $retrySelectorId -OutputEvidencePath $retryEvidencePath -OutputEvidenceName $retryEvidenceName
    Write-TestJson $retrySelectorPath $retrySelector
    $retrySelectorSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $retrySelectorPath).Hash.ToLowerInvariant()
    $retryDispatch = Invoke-MorphospaceWorkUnitAutomation -Action BeginValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick `
        -ValidationSelector $retrySelectorRelative -ExpectedValidationSelectorSha256 $retrySelectorSha -ValidationEvidencePath $retryEvidencePath -Timestamp $fixed -Execute
    Assert-SelectorTest ($retryDispatch.transition -ceq 'active-to-validating' -and $retryDispatch.executed) 'new exact selector did not bind a fresh validation attempt'

    Write-TestCreateNewJson $retryEvidencePath ([ordered]@{
        schema = 'rusty.morphospace.test.unit003.quick-evidence.v1'
        unit_id = $unitId
        result = 'pass'
        legacy_files_read = 0
    })
    $retryEvidenceBytes = [IO.File]::ReadAllBytes($retryEvidencePath)
    New-SelectorValidationReceipt -Workspace $workspace -UnitId $unitId -Result pass -MatrixRow $retryDispatch.validation_matrix[0] -EvidencePath $retryEvidencePath -ReceiptLeaf 'unit-selector-003-pass-validation.json' | Out-Null
    Assert-Rejected 'selector omission on passing RecordValidation' '*requires the exact normal-validation selector and evidence path bound in workspace state*' {
        Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult pass -ValidationReceipt 'receipts/unit-selector-003-pass-validation.json' -Timestamp $fixed
    }
    $passingRecord = Invoke-MorphospaceWorkUnitAutomation -Action RecordValidation -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -ValidationResult pass -ValidationReceipt 'receipts/unit-selector-003-pass-validation.json' `
        -ValidationSelector $retrySelectorRelative -ExpectedValidationSelectorSha256 $retrySelectorSha -ValidationEvidencePath $retryEvidencePath -RepoMapPath $repoMapPath -Timestamp $fixed -Execute
    Assert-SelectorTest ($passingRecord.transition -ceq 'validation-pass' -and $passingRecord.executed) 'passing RecordValidation did not consume the exact selected matrix'
    Assert-Rejected 'selector omission at Accept' '*requires the exact normal-validation selector and evidence path bound in workspace state*' {
        Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -Timestamp $fixed
    }
    [IO.File]::AppendAllText($retryEvidencePath, ' ', [Text.UTF8Encoding]::new($false))
    Assert-Rejected 'selected evidence drift between RecordValidation and Accept' '*Validation artifact hash mismatch*' {
        Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick `
            -ValidationSelector $retrySelectorRelative -ExpectedValidationSelectorSha256 $retrySelectorSha -ValidationEvidencePath $retryEvidencePath -RepoMapPath $repoMapPath -Timestamp $fixed
    }
    [IO.File]::WriteAllBytes($retryEvidencePath, $retryEvidenceBytes)
    $accepted = Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick `
        -ValidationSelector $retrySelectorRelative -ExpectedValidationSelectorSha256 $retrySelectorSha -ValidationEvidencePath $retryEvidencePath -RepoMapPath $repoMapPath -Timestamp $fixed -Execute
    $acceptedState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    Assert-SelectorTest ($accepted.transition -ceq 'validating-to-accepted' -and $accepted.executed -and $null -eq $acceptedState.normal_validation_selection) 'Accept did not validate and clear the exact selector lifecycle binding'
    $acceptedReplay = Invoke-MorphospaceWorkUnitAutomation -Action Accept -WorkspaceRoot $workspace -UnitId $unitId -ValidationTier quick -Timestamp $fixed
    Assert-SelectorTest ($acceptedReplay.transition -ceq 'idempotent') 'accepted lifecycle did not preserve ordinary idempotent replay'

    [pscustomobject][ordered]@{
        schema = 'rusty.morphospace.workflow.normal_validation_selector_self_test.v1'
        result = 'pass'
        positive_dispatch = 'pass'
        ordinary_absence_unchanged = 'pass'
        negative_cases = @(
            'missing-binding', 'orphaned-evidence', 'selector-hash', 'wrong-tier', 'wrong-action', 'selector-location', 'selector-alias', 'selector-duplicate',
            'project-drift', 'unit-drift', 'freeze-receipt-drift', 'producer-drift', 'declared-gate-drift',
            'frozen-repository-drift', 'arbitrary-command', 'evidence-leaf', 'evidence-parent', 'evidence-missing', 'evidence-schema', 'evidence-drift', 'evidence-collision',
            'selector-lifecycle-drift', 'selector-omission', 'return-to-active', 'terminal-selector-release', 'terminal-selector-release-damage',
            'record-validation-pass-fail', 'accept', 'replay'
        )
        producer_executed = $false
        fixture_workflow_lifecycle_mutated = $true
        live_workflow_state_mutated = $false
        product_or_device_used = $false
    } | ConvertTo-Json -Depth 8
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
