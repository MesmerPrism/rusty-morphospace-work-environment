param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'WorkUnitAutomation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReconcilePreparedPushTransactionSuffix.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceProtocolCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\ExternalOwnerAuthorization.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospacePlannedPublication.psm1') -Force

function Write-TestJson([string]$Path,[object]$Value) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($Path,(($Value | ConvertTo-Json -Depth 100) + "`n"),[Text.UTF8Encoding]::new($false))
}
function Copy-TestValue([object]$Value) { $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String }
function Get-TestHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function New-TestFileBinding([string]$Workspace,[string]$Relative) {
    $path = Join-Path $Workspace ($Relative -replace '/','\')
    [pscustomobject][ordered]@{path=$Relative;bytes=[IO.FileInfo]::new($path).Length;sha256=Get-TestHash $path}
}
function New-TestDirtyBinding([string]$Repository,[string]$Relative,[string]$Status) {
    $binding = New-TestFileBinding $Repository $Relative
    [pscustomobject][ordered]@{path=[string]$binding.path;bytes=[int64]$binding.bytes;sha256=[string]$binding.sha256;status=$Status}
}
function Invoke-TestGit([string]$Repository,[string[]]$Arguments) {
    $output = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: git $($Arguments -join ' ')`n$($output -join "`n")" }
    return (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}
function Get-TestCommitPaths([string]$Repository,[string]$Commit) {
    return @(& git -C $Repository diff-tree --no-commit-id --name-only -r $Commit | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -CaseSensitive)
}
function Assert-TestRejected([scriptblock]$Action,[string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Damaged prepared-push suffix case '$Name' was accepted." }
}
function New-TestRepository([string]$Root,[string]$Branch) {
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    Invoke-TestGit $Root @('init','-q','--initial-branch',$Branch) | Out-Null
    Invoke-TestGit $Root @('config','user.name','Workflow Fixture') | Out-Null
    Invoke-TestGit $Root @('config','user.email','fixture@example.invalid') | Out-Null
    Invoke-TestGit $Root @('config','core.autocrlf','false') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root '.gitignore'),"local/`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Root 'base.txt'),"base`n",[Text.UTF8Encoding]::new($false))
    Invoke-TestGit $Root @('add','.') | Out-Null
    Invoke-TestGit $Root @('commit','-q','-m','fixture base') | Out-Null
    return Invoke-TestGit $Root @('rev-parse','HEAD')
}
function Add-TestRemote([string]$Root,[string]$Branch,[string]$Revision) {
    Invoke-TestGit $Root @('remote','add','origin',$Root) | Out-Null
    Invoke-TestGit $Root @('update-ref',"refs/remotes/origin/$Branch",$Revision) | Out-Null
    Invoke-TestGit $Root @('branch','--set-upstream-to',"origin/$Branch",$Branch) | Out-Null
}

if (-not $SelfTest) { throw 'Use -SelfTest.' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('prepared-push-suffix-' + [guid]::NewGuid().ToString('N'))
$rsa = $null
try {
    $source = Join-Path $root 'source'
    $planning = Join-Path $root 'planning'
    $workspace = Join-Path $planning 'project\morphospace'
    $sourceBranch = 'codex/fixture-source'
    $planningBranch = 'codex/fixture-planning'
    $sourceOld = New-TestRepository $source $sourceBranch
    [IO.File]::WriteAllText((Join-Path $source 'feature.txt'),"accepted source`n",[Text.UTF8Encoding]::new($false))
    Invoke-TestGit $source @('add','feature.txt') | Out-Null
    Invoke-TestGit $source @('commit','-q','-m','accepted source change') | Out-Null
    $sourceFinal = Invoke-TestGit $source @('rev-parse','HEAD')
    $sourceTree = Invoke-TestGit $source @('show','-s','--format=%T','HEAD')
    Add-TestRemote $source $sourceBranch $sourceFinal

    $planningOld = New-TestRepository $planning $planningBranch
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'iteration-units')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'receipts')) | Out-Null
    $project = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.project_spec.v1';project_id='fixture-project';revision=1
        purpose='Exercise one signed dirty PreparePush suffix reconciliation.'
        activation_model=[pscustomobject]@{default='disabled';unlisted_modules='inert'}
        authority_map=@([pscustomobject]@{parameter='fixture';owner='source-owner';adapters=@()})
        repositories=@([pscustomobject]@{repo_id='source-owner';role='application';path='<source>';allowed_paths=@('feature.txt')})
        modules=@();non_scope=@('No device work.');validation_profiles=@([pscustomobject]@{profile_id='quick';commands=@('fixture-command')})
        public_boundary=[pscustomobject]@{mode='public';private_overlay='local';prohibited_evidence=@('private evidence')}
    }
    $unitId = 'fixture-publication-unit'
    $unit = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_unit.v1';unit_id=$unitId;project_id='fixture-project';status='accepted'
        objective='Preserve one accepted source commit for publication.';change_categories=@('workflow-automation')
        instruction_impact='none';instruction_surfaces=@();instruction_none_justification='Fixture instructions are unchanged.'
        prerequisites=@();allowed_repositories=@([pscustomobject]@{repo_id='source-owner';allowed_paths=@('feature.txt')})
        non_scope=@('Device work.');acceptance=@([pscustomobject]@{acceptance_id='fixture-pass';proof='Fixture accepted.';command='fixture-command'})
        risk_tier='quick';device_requirement='forbidden';validation=@([pscustomobject]@{profile_id='quick';command='fixture-command'})
        outputs=@('One accepted fixture commit.');commit_policy='Prepare after acceptance.';push_checkpoint='integration-batch'
    }
    $acceptedEventId = 'fixture-publication-unit-accepted-0001'
    $state = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.workspace_state.v2';project_id='fixture-project';plan_revision=1
        current_unit=$null;next_ready_unit=$null;last_event_id=$acceptedEventId;last_accepted_receipt='receipts/fixture-validation.json'
        repository_heads=@([pscustomobject]@{repo_id='source-owner';head=$sourceFinal;branch=$sourceBranch;dirty_fingerprint='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'});repository_checkpoints=@();module_registry=[pscustomobject]@{lock_revision=1;lock_fingerprint=('1'*64);modules=@()};capability_registry=@();dirty_repositories=@()
        blockers=@();validation_checkpoint=[pscustomobject]@{tier='quick';receipt='receipts/fixture-validation.json';result='pass'};pending_push_bundle=$null
    }
    $acceptedEvent = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$acceptedEventId;sequence=1;timestamp='2026-01-01T00:00:00Z'
        project_id='fixture-project';unit_id=$unitId;event_type='state-transition';summary='Accepted the fixture unit.';receipts=@('receipts/fixture-validation.json')
    }
    Write-TestJson (Join-Path $workspace 'project.spec.json') $project
    Write-TestJson (Join-Path $workspace 'feature.lock.json') ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.feature_lock.v1';project_id='fixture-project';revision=1;default_activation='disabled';features=@()})
    Write-TestJson (Join-Path $workspace 'workspace.state.json') $state
    Write-TestJson (Join-Path $workspace "iteration-units\$unitId.json") $unit
    Write-TestJson (Join-Path $workspace 'receipts\fixture-validation.json') ([pscustomobject]@{schema='fixture';unit_id=$unitId;status='accepted';result='pass'})
    [IO.File]::WriteAllText((Join-Path $workspace 'iteration-events.jsonl'),(($acceptedEvent | ConvertTo-Json -Compress -Depth 16) + "`n"),[Text.UTF8Encoding]::new($false))
    Invoke-TestGit $planning @('add','project') | Out-Null
    Invoke-TestGit $planning @('commit','-q','-m','accepted planning state') | Out-Null
    $planningFinal = Invoke-TestGit $planning @('rev-parse','HEAD')
    $planningFinalTree = Invoke-TestGit $planning @('show','-s','--format=%T','HEAD')
    $planningFinalPaths = Get-TestCommitPaths $planning $planningFinal
    Add-TestRemote $planning $planningBranch $planningFinal

    $map = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.repository_map.v1';repositories=@(
        [pscustomobject]@{repo_id='source-owner';path=$source;role='source'},
        [pscustomobject]@{repo_id='planning-owner';path=$planning;role='planning'}
    )}
    $mapPath = Join-Path $root 'repository-map.json'
    Write-TestJson $mapPath $map
    $revisions = [pscustomobject][ordered]@{schema='rusty.morphospace.workflow.revision_set.v1';repositories=@(
        [pscustomobject]@{repo_id='source-owner';commit=$sourceFinal},
        [pscustomobject]@{repo_id='planning-owner';commit=$planningFinal}
    )}
    $revisionsPath = Join-Path $root 'revisions.json'
    Write-TestJson $revisionsPath $revisions
    $prepareRelative = "receipts/$unitId-prepare-push.json"
    $preparePath = Join-Path $workspace ($prepareRelative -replace '/','\')
    $prepare = Invoke-MorphospaceWorkUnitAutomation -Action PreparePush -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $mapPath -RevisionsPath $revisionsPath -Timestamp '2026-01-01T00:01:00Z' -OutPath $preparePath -Execute
    $preparedEventId = [string]$prepare.event_id
    $transactionId = "$preparedEventId-transition"
    $intentRelative = "receipts/transactions/$transactionId.intent.json"
    $completionRelative = "receipts/transactions/$transactionId.completion.json"

    $executedRelative = "receipts/$unitId-executed-push.json"
    $accountingRelative = "receipts/$unitId-accounting.json"
    $executed = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.executed_push_receipt.v1';receipt_id='fixture-executed-push';bundle_id=[string]$prepare.push_plan.bundle_id
        project_id='fixture-project';unit_ids=@($unitId);prepared_plan_id=[string]$prepare.push_plan.bundle_id
        started_at='2026-01-01T00:02:00Z';finished_at='2026-01-01T00:03:00Z';status='validated-pushed';execution='externally-performed'
        dependency_order=@('source-owner','planning-owner');execution_order=@('source-owner','planning-owner')
        repositories=@(
            [pscustomobject][ordered]@{ref_id='source-owner';repo_id='source-owner';role='source-owner';branch=$sourceBranch;remote='origin';upstream="origin/$sourceBranch";action='pushed';old_revision=$sourceOld;new_revision=$sourceFinal;observed_remote_revision=$sourceFinal;push_status='pass';ancestry_verified=$true;remote_match=$true;force_push_used=$false;validation_refs=@('fixture-validation');rollback_revision=$sourceOld},
            [pscustomobject][ordered]@{ref_id='planning-owner';repo_id='planning-owner';role='planning';branch=$planningBranch;remote='origin';upstream="origin/$planningBranch";action='pushed';old_revision=$planningOld;new_revision=$planningFinal;observed_remote_revision=$planningFinal;push_status='pass';ancestry_verified=$true;remote_match=$true;force_push_used=$false;validation_refs=@('fixture-validation');rollback_revision=$planningOld}
        )
        validation=@([pscustomobject][ordered]@{gate_id='fixture-validation';status='pass';evidence=[pscustomobject]@{path='receipts/fixture-validation.json';sha256=Get-TestHash (Join-Path $workspace 'receipts\fixture-validation.json')}})
        rollback=[pscustomobject][ordered]@{strategy='revert-in-reverse-dependency-order';reverse_dependency_order=@('planning-owner','source-owner');points=@(
            [pscustomobject]@{ref_id='planning-owner';rollback_revision=$planningOld;acceptance='Retire the fixture branch without rewriting history.'},
            [pscustomobject]@{ref_id='source-owner';rollback_revision=$sourceOld;acceptance='Retire the fixture branch without rewriting history.'}
        )}
        source_first=$true;planning_last=$true;force_push_used=$false;remote_readback_complete=$true;failure=$null
    }
    Write-TestJson (Join-Path $workspace ($executedRelative -replace '/','\')) $executed
    $unitStatusBinding = [pscustomobject]@{path="iteration-units/$unitId.json";sha256=Get-TestHash (Join-Path $workspace "iteration-units\$unitId.json")}
    $accounting = [pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.planned_publication_accounting.v1';accounting_id='fixture-planned-publication-accounting';project_id='fixture-project'
        bundle_id=[string]$prepare.push_plan.bundle_id;trigger_unit_id=$unitId
        prepared_plan=[pscustomobject]@{container=[pscustomobject]@{path=$prepareRelative;sha256=Get-TestHash $preparePath};member='push_plan'}
        prepared_event=[pscustomobject]@{transaction_id=$transactionId;event_id=$preparedEventId;intent=[pscustomobject]@{path=$intentRelative;sha256=Get-TestHash (Join-Path $workspace ($intentRelative-replace'/','\'))};completion=[pscustomobject]@{path=$completionRelative;sha256=Get-TestHash (Join-Path $workspace ($completionRelative-replace'/','\'))}}
        executed_push_receipt=[pscustomobject]@{path=$executedRelative;sha256=Get-TestHash (Join-Path $workspace ($executedRelative-replace'/','\'))}
        chronology=[pscustomobject]@{prepared_at='2026-01-01T00:01:00Z';push_started_at='2026-01-01T00:02:00Z';push_finished_at='2026-01-01T00:03:00Z';accounted_at='2026-01-01T00:04:00Z'}
        dependency_order=@('source-owner','planning-owner');execution_order=@('source-owner','planning-owner')
        repositories=@(
            [pscustomobject][ordered]@{repo_id='source-owner';role='source';branch=$sourceBranch;upstream="origin/$sourceBranch";old_revision=$sourceOld;prepared_revision=$sourceFinal;final_revision=$sourceFinal;remote_readback_revision=$sourceFinal;source_first=$true;planning_last=$false;fast_forward_verified=$true;force_push_used=$false;worktree_clean=$true;units=@([pscustomobject]@{unit_id=$unitId;role='triggering-unit';status_at_publication='accepted';status_evidence=$unitStatusBinding;no_acceptance_claim=$false});commits=@([pscustomobject]@{revision=$sourceFinal;role='triggering-unit';unit_id=$unitId;changed_paths=@('feature.txt')});allowed_finalization_paths=@()},
            [pscustomobject][ordered]@{repo_id='planning-owner';role='planning-transport';branch=$planningBranch;upstream="origin/$planningBranch";old_revision=$planningOld;prepared_revision=$planningFinal;final_revision=$planningFinal;remote_readback_revision=$planningFinal;source_first=$false;planning_last=$true;fast_forward_verified=$true;force_push_used=$false;worktree_clean=$true;units=@([pscustomobject]@{unit_id=$unitId;role='triggering-unit';status_at_publication='accepted';status_evidence=$unitStatusBinding;no_acceptance_claim=$false});commits=@([pscustomobject]@{revision=$planningFinal;role='triggering-unit';unit_id=$unitId;changed_paths=$planningFinalPaths});allowed_finalization_paths=@()}
        )
        workspace_transition=[pscustomobject]@{pending_push_bundle_before=[string]$prepare.push_plan.bundle_id;pending_push_bundle_after=$null}
        force_push_used=$false;remote_readback_complete=$true;failure=$null
    }
    $accountingPath = Join-Path $workspace ($accountingRelative -replace '/','\')
    Write-TestJson $accountingPath $accounting
    Test-MorphospacePlannedPublicationDocument -Path $accountingPath -WorkspaceRoot $workspace | Out-Null
    Invoke-TestGit $planning @('add',"project/morphospace/$executedRelative","project/morphospace/$accountingRelative") | Out-Null
    Invoke-TestGit $planning @('commit','-q','-m','receipt-only prerequisite suffix') | Out-Null
    $suffixRevision = Invoke-TestGit $planning @('rev-parse','HEAD')
    $suffixTree = Invoke-TestGit $planning @('show','-s','--format=%T','HEAD')

    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $publicPem = $rsa.ExportSubjectPublicKeyInfoPem().Replace("`r",'')
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    $policyPath = Join-Path $root 'test-policy.json'
    $policySchemaPath = Join-Path $root 'test-policy.schema.json'
    Write-TestJson $policyPath ([pscustomobject][ordered]@{schema='rusty.morphospace.workflow.external_owner_authorization_policy.v1';issuer_id='fixture-owner-authority';owner_login='Owner';comment_marker='fixture-owner';max_authorization_age_seconds=86400;max_future_skew_seconds=300;maximum_comments=100;maximum_response_bytes=1048576;maximum_comment_bytes=65536;public_key_spki_sha256=$fingerprint;public_key_pem=$publicPem})
    Write-TestJson $policySchemaPath ([pscustomobject][ordered]@{'$schema'='https://json-schema.org/draft/2020-12/schema';type='object';required=@('schema','issuer_id','owner_login','comment_marker','max_authorization_age_seconds','max_future_skew_seconds','maximum_comments','maximum_response_bytes','maximum_comment_bytes','public_key_spki_sha256','public_key_pem');properties=[pscustomobject]@{schema=[pscustomobject]@{const='rusty.morphospace.workflow.external_owner_authorization_policy.v1'};issuer_id=[pscustomobject]@{type='string'};owner_login=[pscustomobject]@{type='string'};comment_marker=[pscustomobject]@{type='string'};max_authorization_age_seconds=[pscustomobject]@{type='integer'};max_future_skew_seconds=[pscustomobject]@{type='integer'};maximum_comments=[pscustomobject]@{type='integer'};maximum_response_bytes=[pscustomobject]@{type='integer'};maximum_comment_bytes=[pscustomobject]@{type='integer'};public_key_spki_sha256=[pscustomobject]@{type='string'};public_key_pem=[pscustomobject]@{type='string'}};additionalProperties=$false})

    $statePath = Join-Path $workspace 'workspace.state.json'
    $unitPath = Join-Path $workspace "iteration-units\$unitId.json"
    $eventsPath = Join-Path $workspace 'iteration-events.jsonl'
    $intentPath = Join-Path $workspace ($intentRelative -replace '/','\')
    $completionPath = Join-Path $workspace ($completionRelative -replace '/','\')
    $dirty = @(
        New-TestDirtyBinding $planning 'project/morphospace/iteration-events.jsonl' 'modified'
        New-TestDirtyBinding $planning "project/morphospace/$prepareRelative" 'untracked'
        New-TestDirtyBinding $planning "project/morphospace/$completionRelative" 'untracked'
        New-TestDirtyBinding $planning "project/morphospace/$intentRelative" 'untracked'
        New-TestDirtyBinding $planning 'project/morphospace/workspace.state.json' 'modified'
    ) | Sort-Object path -CaseSensitive
    $document = [pscustomobject][ordered]@{
        '$schema'='../schemas/prepared-push-transaction-suffix-reconciliation-v1.schema.json'
        schema='rusty.morphospace.workflow.prepared_push_transaction_suffix_reconciliation.v1';reconciliation_id='fixture-prepared-push-suffix-reconciliation';project_id='fixture-project';unit_id=$unitId;bundle_id=[string]$prepare.push_plan.bundle_id
        reason='Bind one exact signed five-path PreparePush suffix without changing source or ordinary publication accounting.'
        expected=[pscustomobject]@{unit_status='accepted';current_unit=$null;unit_raw_sha256=Get-TestHash $unitPath;unit_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $unitPath);state_raw_sha256=Get-TestHash $statePath;state_canonical_sha256=Get-MorphospaceCanonicalJsonSha256 (Read-MorphospaceProtocolJson $statePath);events_sha256=Get-TestHash $eventsPath;events_length=[IO.FileInfo]::new($eventsPath).Length;event_tail_id=$preparedEventId}
        prepared_plan=[pscustomobject]@{container=New-TestFileBinding $workspace $prepareRelative;member='push_plan'}
        prepared_event=[pscustomobject]@{transaction_id=$transactionId;event_id=$preparedEventId;intent=New-TestFileBinding $workspace $intentRelative;completion=New-TestFileBinding $workspace $completionRelative}
        executed_push_receipt=New-TestFileBinding $workspace $executedRelative
        planned_publication_accounting=New-TestFileBinding $workspace $accountingRelative
        source_repositories=@([pscustomobject]@{repo_id='source-owner';branch=$sourceBranch;upstream="origin/$sourceBranch";parent_revision=$sourceOld;revision=$sourceFinal;tree=$sourceTree;history_mode='linear';worktree_clean=$true})
        planning_transport=[pscustomobject]@{repo_id='planning-owner';branch=$planningBranch;upstream="origin/$planningBranch";execution_final_revision=$planningFinal;execution_final_tree=$planningFinalTree;receipt_suffix_revision=$suffixRevision;receipt_suffix_tree=$suffixTree;receipt_suffix_parent=$planningFinal;receipt_suffix_commit_count=1;receipt_suffix_paths=@("project/morphospace/$accountingRelative","project/morphospace/$executedRelative")|Sort-Object -CaseSensitive;dirty_prepare_paths=$dirty;worktree_expected_dirty=$true}
        workspace_transition=[pscustomobject]@{pending_push_bundle_before=[string]$prepare.push_plan.bundle_id;pending_push_bundle_after=$null;unit_unchanged=$true;validation_unchanged=$true;acceptance_unchanged=$true}
        preservation=[pscustomobject]@{existing_evidence_bytes_unchanged=$true;existing_timestamps_unchanged=$true;ordinary_record_publication_unchanged=$true;git_mutation_performed=$false;source_mutation_performed=$false;device_mutation_performed=$false;acceptance_mutation_performed=$false;publication_authority_claimed=$false}
        authorization=[pscustomobject]@{schema='rusty.morphospace.workflow.prepared_push_transaction_suffix_authorization.v1';payload=[pscustomobject]@{issuer_id='fixture-owner-authority';authorization_id='fixture-suffix-authorization';project_id='fixture-project';unit_id=$unitId;bundle_id=[string]$prepare.push_plan.bundle_id;scope_sha256=('0'*64);issued_at='2026-01-01T00:05:00Z';expires_at='2026-01-01T01:05:00Z';decision='authorize-prepared-push-transaction-suffix-reconciliation';limitations=@('matching_pending_bundle_only','preserve_existing_evidence_bytes','workflow_state_only','git_mutation=false','acceptance_mutation=false','publication_authority=false')};signature=[pscustomobject]@{algorithm='RSA-PSS-SHA256';public_key_spki_sha256=$fingerprint;value_base64='AA=='}}
        failure=$null
    }
    $signDocument = {
        param([object]$Value)
        $Value.authorization.payload.project_id = [string]$Value.project_id
        $Value.authorization.payload.unit_id = [string]$Value.unit_id
        $Value.authorization.payload.bundle_id = [string]$Value.bundle_id
        $scope = Get-PreparedPushSuffixAuthorizationScope $Value
        [byte[]]$scopeBytes = Get-CanonicalAuthorizationBytes $scope
        $Value.authorization.payload.scope_sha256 = Get-ExternalOwnerSha256 $scopeBytes
        [byte[]]$payloadBytes = Get-CanonicalAuthorizationBytes $Value.authorization.payload
        [byte[]]$signature = $rsa.SignData($payloadBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
        $Value.authorization.signature.value_base64 = [Convert]::ToBase64String($signature)
        return $Value
    }

    # Exercise the public signing helper in a fresh process. Its repository-pinned
    # key must reject this fixture key, but only after every helper command remains
    # visible across the nested reconciliation-module imports.
    $helperDraftPath = Join-Path $planning 'local\fixture-prepared-push-suffix-helper-draft.json'
    $helperKeyPath = Join-Path $planning 'local\fixture-prepared-push-suffix-helper-key.pem'
    $helperOutPath = Join-Path $planning 'local\fixture-prepared-push-suffix-helper-signed.json'
    Write-TestJson $helperDraftPath $document
    [IO.File]::WriteAllText($helperKeyPath,$rsa.ExportPkcs8PrivateKeyPem().Replace("`r",''),[Text.UTF8Encoding]::new($false))
    $helperIssued = [datetimeoffset]::UtcNow
    $helperTimestampFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    $helperIssuedText = $helperIssued.ToString($helperTimestampFormat,[Globalization.CultureInfo]::InvariantCulture)
    $helperExpiresText = $helperIssued.AddHours(1).ToString($helperTimestampFormat,[Globalization.CultureInfo]::InvariantCulture)
    $nativeCommandPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $helperOutput = @(& pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $PSScriptRoot 'New-PreparedPushTransactionSuffixAuthorization.ps1') `
            -DraftPath $helperDraftPath `
            -AuthorizationId 'fixture-standalone-helper-import-lifetime' `
            -IssuedAt $helperIssuedText `
            -ExpiresAt $helperExpiresText `
            -PrivateKeyPemPath $helperKeyPath `
            -OutPath $helperOutPath 2>&1)
        $helperExitCode = $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $nativeCommandPreference
    }
    $helperText = ($helperOutput | ForEach-Object { [string]$_ }) -join "`n"
    if ($helperExitCode -eq 0 -or $helperText -cnotmatch 'Signing key does not equal the pinned external owner key\.' -or
        $helperText -match "Read-MorphospaceProtocolJson'.*not recognized" -or [IO.File]::Exists($helperOutPath)) {
        throw "Standalone signing-helper import-lifetime regression failed (exit $helperExitCode): $helperText"
    }

    $document = & $signDocument $document
    $inputPath = Join-Path $planning 'local\fixture-prepared-push-suffix.json'
    Write-TestJson $inputPath $document
    $now = [datetimeoffset]'2026-01-01T00:06:00Z'
    Test-MorphospacePreparedPushTransactionSuffixReconciliation -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $mapPath -Reconciliation $inputPath -AuthorizationPolicyPath $policyPath -AuthorizationPolicySchemaPath $policySchemaPath -Now $now | Out-Null

    $cases = @('missing-dirty','extra-dirty','wrong-hash','wrong-unit','wrong-bundle','wrong-parent','status-overclaim','authorization-metadata-tamper','bad-signature')
    foreach ($case in $cases) {
        $bad = Copy-TestValue $document
        switch ($case) {
            'missing-dirty' { $bad.planning_transport.dirty_prepare_paths=@($bad.planning_transport.dirty_prepare_paths|Select-Object -First 4) }
            'extra-dirty' { $bad.planning_transport.dirty_prepare_paths+=Copy-TestValue $bad.planning_transport.dirty_prepare_paths[0] }
            'wrong-hash' { $bad.expected.events_sha256=('0'*64) }
            'wrong-unit' { $bad.unit_id='other-unit' }
            'wrong-bundle' { $bad.bundle_id='other-bundle';$bad.workspace_transition.pending_push_bundle_before='other-bundle' }
            'wrong-parent' { $bad.source_repositories[0].parent_revision=$sourceFinal }
            'status-overclaim' { $bad.workspace_transition.acceptance_unchanged=$false }
            'authorization-metadata-tamper' { $bad.authorization.payload.authorization_id='substituted-authorization' }
            'bad-signature' { $bad.authorization.signature.value_base64='AA==' }
        }
        if ($case -notin @('authorization-metadata-tamper','bad-signature')) { $bad = & $signDocument $bad }
        $badPath = Join-Path $planning "local\bad-$case.json"
        Write-TestJson $badPath $bad
        Assert-TestRejected { Test-MorphospacePreparedPushTransactionSuffixReconciliation -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $mapPath -Reconciliation $badPath -AuthorizationPolicyPath $policyPath -AuthorizationPolicySchemaPath $policySchemaPath -Now $now } $case
    }
    [byte[]]$preparedStateBytes = [IO.File]::ReadAllBytes($statePath)
    $changedState = Copy-TestValue (Read-MorphospaceProtocolJson $statePath)
    $changedState.current_unit = $unitId
    Write-TestJson $statePath $changedState
    Assert-TestRejected { Test-MorphospacePreparedPushTransactionSuffixReconciliation -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $mapPath -Reconciliation $inputPath -AuthorizationPolicyPath $policyPath -AuthorizationPolicySchemaPath $policySchemaPath -Now $now } 'current-unit-misuse'
    [IO.File]::WriteAllBytes($statePath,$preparedStateBytes)
    [IO.File]::WriteAllText((Join-Path $source 'unexpected.txt'),"dirty`n",[Text.UTF8Encoding]::new($false))
    Assert-TestRejected { Test-MorphospacePreparedPushTransactionSuffixReconciliation -WorkspaceRoot $workspace -UnitId $unitId -RepoMapPath $mapPath -Reconciliation $inputPath -AuthorizationPolicyPath $policyPath -AuthorizationPolicySchemaPath $policySchemaPath -Now $now } 'dirty-source'
    Remove-Item -LiteralPath (Join-Path $source 'unexpected.txt') -Force

    $module = Get-Module ReconcilePreparedPushTransactionSuffix
    $outPath = Join-Path $workspace 'receipts\fixture-prepared-push-suffix-reconciliation.json'
    $parameters = @{
        WorkspaceRoot=$workspace;UnitId=$unitId;RepoMapPath=$mapPath;Reconciliation=$inputPath;OutPath=$outPath
        ExpectedReconciliationSha256=Get-TestHash $inputPath;Timestamp='2026-01-01T00:07:00.0000000Z'
        AuthorizationPolicyPath=$policyPath;AuthorizationPolicySchemaPath=$policySchemaPath;AuthorizationNow=$now;Execute=$true
    }
    $unitBefore = [IO.File]::ReadAllBytes($unitPath)
    $result = & $module { param($values) Invoke-PreparedPushTransactionSuffixReconciliationCore @values } $parameters
    $afterState = Read-MorphospaceProtocolJson $statePath
    $unitAfter = [IO.File]::ReadAllBytes($unitPath)
    if ($result.transition -cne 'prepared-push-transaction-suffix-reconciled' -or $null -ne $afterState.pending_push_bundle -or
        -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($unitBefore,$unitAfter) -or -not [IO.File]::Exists($outPath) -or
        (Get-TestHash $outPath) -cne (Get-TestHash $inputPath) -or [string]$result.audit_receipt.sha256 -cne (Get-TestHash $inputPath)) {
        throw 'Positive execution did not consume only the matching bundle while preserving exact unit and audit-receipt bytes.'
    }
    Assert-TestRejected { & $module { param($values) Invoke-PreparedPushTransactionSuffixReconciliationCore @values } $parameters } 'repeated-consumption'
    "Prepared-push transaction suffix reconciliation self-test passed (1 signed live positive, 1 exact transactional consumption, $($cases.Count + 3) damaged cases)."
} finally {
    if ($null -ne $rsa) { $rsa.Dispose() }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
