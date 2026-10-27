Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceSourceCompositionIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospaceTransitionLedger.psm1')
$script:BootstrapObservation = Import-Module (Join-Path $PSScriptRoot 'MorphospaceContentObservation.psm1') -PassThru -DisableNameChecking
$script:BootstrapPathComparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$script:BootstrapArtifactIds = @('bootstrap-source-lock','bootstrap-repository-map','bootstrap-begin-intent')

function Copy-BootstrapValidationValue([object]$Value) {
    ConvertFrom-MorphospaceProtocolJsonBytes (ConvertTo-MorphospaceProtocolJsonBytes $Value)
}
function Read-BootstrapValidationFile([string]$Path,[hashtable]$Files) {
    $absolute=[IO.Path]::GetFullPath($Path)
    if(-not[IO.File]::Exists($absolute)){throw "Bootstrap validation input is missing: $absolute"}
    $cursor=$absolute
    while($cursor){
        if(([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Bootstrap validation input traverses a reparse point.'}
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent-ceq$cursor){break};$cursor=$parent
    }
    $bytes=[IO.File]::ReadAllBytes($absolute);$hash=Get-MorphospaceSha256Bytes $bytes
    if($Files.ContainsKey($absolute)-and[string]$Files[$absolute]-cne$hash){throw 'Bootstrap validation input changed during authentication.'}
    $Files[$absolute]=$hash
    ConvertFrom-MorphospaceProtocolJsonBytes $bytes
}
function Assert-BootstrapValidationSchema([object]$Value,[string]$Name) {
    $schema=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "schemas/$Name"
    if(-not(Test-Json -Json ($Value|ConvertTo-Json -Depth 100) -SchemaFile $schema -ErrorAction Stop)){throw "Bootstrap validation document is malformed: $Name"}
}
function Invoke-BootstrapValidationGit([string]$Root,[string[]]$Arguments,[switch]$AllowFailure) {
    if(-not(Get-Variable BootstrapGit -Scope Script -ErrorAction SilentlyContinue)){
        $script:BootstrapGit=&$script:BootstrapObservation {Get-MorphospaceBoundExecutable -Name git}
    }
    $result=&$script:BootstrapObservation {
        param($exe,$hash,$root,$argv,$allow)
        Invoke-MorphospaceBoundGitBytes -GitExecutable $exe -ExpectedExecutableSha256 $hash -RepositoryPath $root -Arguments $argv -TimeoutSeconds 30 -MaxOutputBytes 4194304 -AllowFailure:$allow
    } $script:BootstrapGit.path $script:BootstrapGit.sha256 $Root $Arguments $AllowFailure.IsPresent
    [pscustomobject]@{exit_code=[int]$result.exit_code;text=[Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$result.stdout)}
}
function Get-BootstrapValidationGitObservation([string]$Root) {
    $head=(Invoke-BootstrapValidationGit $Root @('rev-parse','HEAD')).text.Trim()
    $tree=(Invoke-BootstrapValidationGit $Root @('rev-parse','HEAD^{tree}')).text.Trim()
    $branchResult=Invoke-BootstrapValidationGit $Root @('symbolic-ref','--quiet','--short','HEAD') -AllowFailure
    $branch=if($branchResult.exit_code-eq0){$branchResult.text.Trim()}else{$null}
    $status=(Invoke-BootstrapValidationGit $Root @('status','--porcelain=v1','-z','--untracked-files=all')).text
    if($head-cnotmatch'^[0-9a-f]{40}$'-or$tree-cnotmatch'^[0-9a-f]{40}$'){throw 'Bootstrap validation repository observation lacks exact Git objects.'}
    [pscustomobject]@{path=$Root;head=$head;tree=$tree;branch=$branch;status=$status}
}
function Test-BootstrapValidationPath([string]$Path,[object[]]$Allowed) {
    foreach($item in $Allowed){$prefix=([string]$item).Replace('\','/').TrimEnd('/');if($Path-ceq$prefix-or$Path.StartsWith($prefix+'/',[StringComparison]::Ordinal)){return $true}}
    return $false
}
function Assert-BootstrapValidationUnit([object]$Unit) {
    foreach($name in @('agent_scope_assessment','candidate_freeze','tooling_context')){
        if($Unit.PSObject.Properties.Name-ccontains$name){throw 'Bootstrap validation excludes admitted, frozen or tooling-context units.'}
    }
    if(@($Unit.prerequisites).Count-ne0){throw 'Bootstrap validation excludes a unit with accepted prerequisites.'}
}
function Get-BootstrapValidationStep([string]$Workspace,[object]$Event,[hashtable]$Files) {
    $transaction="$([string]$Event.event_id)-transition"
    $intentPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$transaction.intent.json" -RequireLeaf
    $intent=Read-BootstrapValidationFile $intentPath $Files
    $completionPath=Resolve-MorphospaceWorkspacePath $Workspace "receipts/transactions/$transaction.completion.json" -RequireLeaf
    $null=Read-BootstrapValidationFile $completionPath $Files
    $step=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $Workspace -TransactionId $transaction -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath ([string]$intent.unit.path) -ExpectedEventsPath 'iteration-events.jsonl'
    if((Get-MorphospaceCanonicalJsonSha256 $Event)-cne(Get-MorphospaceCanonicalJsonSha256 $step.intent.event)){throw 'Bootstrap validation origin transition is damaged: event differs.'}
    foreach($artifact in @($intent.artifacts)){
        $path=Resolve-MorphospaceWorkspacePath $Workspace ([string]$artifact.path) -RequireLeaf
        $Files[$path]=Get-MorphospaceFileSha256 $path
    }
    [pscustomobject]@{intent=$step.intent;intent_path=$intentPath;completion_path=$completionPath}
}
function Assert-MorphospaceBootstrapValidationObservation {
    [CmdletBinding()]param([Parameter(Mandatory)][object]$Authority)
    foreach($path in $Authority.recheck_files.Keys){
        if(-not[IO.File]::Exists($path)-or(Get-MorphospaceFileSha256 $path)-cne[string]$Authority.recheck_files[$path]){throw 'Bootstrap validation input changed during authentication.'}
    }
    foreach($before in @($Authority.repository_observations)){
        $after=Get-BootstrapValidationGitObservation ([string]$before.path)
        if((Get-MorphospaceCanonicalJsonSha256 $after)-cne(Get-MorphospaceCanonicalJsonSha256 $before)){throw 'Bootstrap validation repository observation changed.'}
    }
}

function Get-MorphospaceBootstrapValidationAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$UnitId,[Parameter(Mandatory)][string]$RepoMapPath,[AllowNull()][object]$Receipt=$null,[string]$ReceiptPath='')
    $workspace=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path).TrimEnd('\','/')
    $mutex=Enter-MorphospaceWorkspaceMutex $workspace
    try{
        $files=@{};$repositories=@();$baseByRepo=@{}
        $project=Read-BootstrapValidationFile (Resolve-MorphospaceWorkspacePath $workspace 'project.spec.json' -RequireLeaf) $files
        $unit=Read-BootstrapValidationFile (Resolve-MorphospaceWorkspacePath $workspace "iteration-units/$UnitId.json" -RequireLeaf) $files
        $state=Read-BootstrapValidationFile (Resolve-MorphospaceWorkspacePath $workspace 'workspace.state.json' -RequireLeaf) $files
        $feature=Read-BootstrapValidationFile (Resolve-MorphospaceWorkspacePath $workspace 'feature.lock.json' -RequireLeaf) $files
        Assert-BootstrapValidationSchema $project 'project-spec-v2.schema.json';Assert-BootstrapValidationSchema $unit 'iteration-unit.schema.json';Assert-BootstrapValidationSchema $state 'workspace-state-v2.schema.json';Assert-BootstrapValidationSchema $feature 'feature-lock-v2.schema.json'
        Assert-BootstrapValidationUnit $unit
        $accepted=[string]$unit.status-ceq'accepted'
        if([string]$unit.unit_id-cne$UnitId-or[string]$unit.project_id-cne[string]$project.project_id-or[string]$state.project_id-cne[string]$project.project_id-or
           ((-not$accepted)-and([string]$unit.status-cne'validating'-or[string]$state.current_unit-cne$UnitId))-or
           ($accepted-and($null-ne$state.current_unit-or$null-eq$Receipt))){throw 'Bootstrap validation requires the matching validating or accepted unit.'}
        if($null-eq$Receipt-and$null-ne$state.last_accepted_receipt){throw 'Bootstrap validation requires an initial owner without an accepted predecessor.'}
        if($null-ne$state.next_ready_unit-or$null-ne$state.pending_push_bundle-or@($state.blockers).Count-ne0-or
           ($state.PSObject.Properties.Name-ccontains'normal_validation_selection'-and$null-ne$state.normal_validation_selection)){throw 'Bootstrap validation excludes queued, blocked, selected or publishing authority.'}
        if([string]$feature.project_id-cne[string]$project.project_id-or[int]$feature.project_revision-ne[int]$project.revision-or
           [int]$state.module_registry.lock_revision-ne[int]$feature.revision-or[string]$state.module_registry.lock_fingerprint-cne[string]$feature.lock_fingerprint-or-not(Test-MorphospaceFeatureLockFingerprint $feature)){throw 'Bootstrap validation project, feature lock and state differ.'}
        $profiles=@{};foreach($profile in @($project.validation_profiles)){$profiles[[string]$profile.profile_id]=$true}
        foreach($profile in @($unit.validation)){if(-not$profiles.ContainsKey([string]$profile.profile_id)){throw 'Bootstrap validation current unit has an unknown validation profile.'}}
        if($unit.PSObject.Properties.Name-cnotcontains'source_composition'-or[string]$unit.source_composition.mode-cne'exact-lock'-or$null-ne$unit.source_composition.materialization_receipt){throw 'Bootstrap validation source lock is missing or malformed.'}
        $lockPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$unit.source_composition.lock_path) -RequireLeaf
        $source=Read-BootstrapValidationFile $lockPath $files;Assert-BootstrapValidationSchema $source 'source-composition-lock.schema.json'
        if([string]$source.project_id-cne[string]$project.project_id-or[string]$source.unit_id-cne$UnitId-or
           [string]$source.fingerprint-cne(Get-MorphospaceSourceCompositionFingerprint -ProjectId ([string]$project.project_id) -UnitId $UnitId -Repositories @($source.repositories))-or
           [string]$source.lock_id-cne"$UnitId-source-$(([string]$source.fingerprint).Substring(0,12))"){throw 'Bootstrap validation source lock fingerprint is detached.'}
        $mapPath=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoMapPath).Path)
        $map=Read-BootstrapValidationFile $mapPath $files;Assert-BootstrapValidationSchema $map 'repository-map.schema.json'
        $receiptRawHash=$null;$actualReceiptPath=$null
        if($null-ne$Receipt){
            if(-not$ReceiptPath){throw 'Bootstrap validation consumed receipt path is missing.'}
            $actualReceiptPath=[IO.Path]::GetFullPath($ReceiptPath)
            $actualReceipt=Read-BootstrapValidationFile $actualReceiptPath $files
            if((Get-MorphospaceCanonicalJsonSha256 $actualReceipt)-cne(Get-MorphospaceCanonicalJsonSha256 $Receipt)){throw 'Bootstrap validation consumed receipt object differs from its actual bytes.'}
            $receiptRawHash=[string]$files[$actualReceiptPath]
        }
        $mapByRepo=@{};foreach($row in @($map.repositories)){if($mapByRepo.ContainsKey([string]$row.repo_id)){throw 'Bootstrap validation repository map repeats an identity.'};$mapByRepo[[string]$row.repo_id]=$row}
        $eventsPath=Resolve-MorphospaceWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf
        $files[$eventsPath]=Get-MorphospaceFileSha256 $eventsPath
        $events=@([IO.File]::ReadAllLines($eventsPath)|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json -Depth 100 -DateKind String})
        if($events.Count-lt3-or[string]$events[-1].event_id-cne[string]$state.last_event_id){throw 'Bootstrap validation requires authenticated native Ready and Claim.'}
        $previous=$null;$previousUnit=$null;$claimed=$false;$begin=$null;$record=$null;$retainedReceiptPath=$null;$correction=$null;$acceptedStep=$false;$seen=@{}
        foreach($event in $events){
            if([int]$event.sequence-ne$seen.Count+1-or$seen.ContainsKey([string]$event.event_id)-or[string]$event.project_id-cne[string]$project.project_id){throw 'Bootstrap validation origin transition is damaged: event order.'}
            $seen[[string]$event.event_id]=$true
            $step=Get-BootstrapValidationStep $workspace $event $files;$intent=$step.intent;$target=$intent.target.state.document;$targetUnit=$intent.target.unit.document
            Assert-BootstrapValidationUnit $targetUnit
            $isCorrection=$false
            if($null-ne$previous-and[string]$intent.pre.state.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $previous)){throw 'Bootstrap validation origin transition is damaged: state preimage.'}
            if($null-eq$previous){
                $proposed=Copy-BootstrapValidationValue $targetUnit;$proposed.status='proposed'
                if([string]$targetUnit.status-cne'ready'-or$null-ne$target.current_unit-or[string]$target.next_ready_unit-cne[string]$targetUnit.unit_id-or
                   $null-ne$intent.expected.event_tail_id-or[int64]$intent.expected.events_length-ne0-or@($intent.artifacts).Count-ne0-or
                   [string]$event.event_id-cnotmatch('-ready-[0-9]{4,}$')-or(Get-MorphospaceCanonicalJsonSha256 $proposed)-cne[string]$intent.pre.unit.sha256){throw 'Bootstrap validation requires authenticated native Ready and Claim.'}
            }elseif([string]$intent.schema-ceq'rusty.morphospace.workflow.transition_ledger_intent.v2'){
                if(-not$claimed-or$null-ne$begin-or$null-ne$record-or[string]$previousUnit.status-cne'active'-or
                   [string]$intent.supersession.old_unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $previousUnit)){throw 'Bootstrap validation supersession origin is detached.'}
                $receiptArtifact=@($intent.artifacts);if($receiptArtifact.Count-ne1){throw 'Bootstrap validation supersession receipt is detached.'}
                $audit=Read-BootstrapValidationFile (Resolve-MorphospaceWorkspacePath $workspace ([string]$receiptArtifact[0].path) -RequireLeaf) $files
                $requestPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$audit.audit_receipt.path) -RequireLeaf
                $request=Read-BootstrapValidationFile $requestPath $files;Assert-BootstrapValidationSchema $request 'active-unit-supersession-v1.schema.json'
                if([string]$audit.audit_receipt.sha256-cne$files[$requestPath]-or[string]$request.expected.repository_map_sha256-cne$files[$mapPath]){throw 'Bootstrap validation supersession repository map is detached.'}
                # The generic ledger already validates the v2 embedded old-unit
                # and pre-state binding. Recheck the typed owner request here
                # without importing Supersession (which force-reloads WUA).
                Assert-BootstrapValidationSchema $audit 'work-unit-automation-receipt-v2.schema.json'
                $preReplacement=Copy-BootstrapValidationValue $targetUnit;$preReplacement.status='proposed'
                $expectedState=Copy-BootstrapValidationValue $previous;$expectedState.current_unit=[string]$targetUnit.unit_id;$expectedState.next_ready_unit=$null;$expectedState.last_event_id=[string]$event.event_id
                if([string]$audit.action-cne'SupersedeActive'-or-not[bool]$audit.executed-or[string]$audit.event_id-cne[string]$event.event_id-or
                   [string]$audit.transition-cne'active-superseded-by-proposed-to-active'-or[string]$audit.project_id-cne[string]$project.project_id-or
                   [string]$audit.current_unit_before-cne[string]$previousUnit.unit_id-or[string]$audit.current_unit_after-cne[string]$targetUnit.unit_id-or
                   [string]$request.supersession_id-cne[string]$event.event_id-or[string]$request.old_unit.unit_id-cne[string]$previousUnit.unit_id-or
                   [string]$request.replacement_unit.unit_id-cne[string]$targetUnit.unit_id-or[string]$request.replacement_unit.canonical_sha256-cne[string]$intent.pre.unit.sha256-or
                   (Get-MorphospaceCanonicalJsonSha256 $preReplacement)-cne[string]$intent.pre.unit.sha256-or
                   [string]$request.expected.state_canonical_sha256-cne[string]$intent.pre.state.sha256-or
                   [string]$request.expected.events_sha256-cne[string]$intent.expected.events_sha256-or
                   [int64]$request.expected.events_length-ne[int64]$intent.expected.events_length-or
                   [string]$request.expected.event_tail_id-cne[string]$intent.expected.event_tail_id-or
                   (Get-MorphospaceCanonicalJsonSha256 $expectedState)-cne[string]$intent.target.state.sha256-or@($request.companion_units).Count-ne0){throw 'Bootstrap validation supersession origin is detached.'}
                $oldPath=Resolve-MorphospaceWorkspacePath $workspace ([string]$request.old_unit.path) -RequireLeaf
                $old=Read-BootstrapValidationFile $oldPath $files
                if([string]$request.old_unit.raw_sha256-cne$files[$oldPath]-or(Get-MorphospaceCanonicalJsonSha256 $old)-cne(Get-MorphospaceCanonicalJsonSha256 $previousUnit)){throw 'Bootstrap validation supersession preserved unit is detached.'}
                foreach($repo in @($targetUnit.allowed_repositories)){
                    $oldRepo=@($previousUnit.allowed_repositories|Where-Object{[string]$_.repo_id-ceq[string]$repo.repo_id})
                    if($oldRepo.Count-ne1){throw 'Bootstrap validation supersession widens repository scope.'}
                    foreach($path in @($repo.allowed_paths)){if(-not(Test-BootstrapValidationPath ([string]$path).Replace('\','/').TrimEnd('/') @($oldRepo[0].allowed_paths))){throw 'Bootstrap validation supersession widens path scope.'}}
                }
            }else{
                if([string]$intent.pre.unit.sha256-cne(Get-MorphospaceCanonicalJsonSha256 $previousUnit)){throw 'Bootstrap validation origin transition is damaged: unit preimage.'}
                $expectedUnit=Copy-BootstrapValidationValue $previousUnit
                if(-not$claimed){
                    $expectedUnit.status='active'
                    if([string]$event.event_id-cnotmatch'-claimed-[0-9]{4,}$'-or[string]$target.current_unit-cne[string]$targetUnit.unit_id-or$null-ne$target.next_ready_unit-or@($intent.artifacts).Count-ne0){throw 'Bootstrap validation requires authenticated native Ready and Claim.'}
                    $claimed=$true
                }elseif($null-eq$begin-and[string]$previousUnit.status-ceq'active'-and[string]$targetUnit.status-ceq'validating'){
                    $expectedUnit.status='validating'
                    if([string]$event.event_id-cnotmatch'-validating-[0-9]{4,}$'-or@($intent.artifacts).Count-ne0){throw 'Bootstrap validation Begin is not the ordinary native transition.'}
                    $begin=$step
                }elseif($intent.PSObject.Properties.Name-ccontains'additional_projections'){
                    if($null-ne$correction-or$null-ne$record){throw 'Bootstrap validation repeats or misplaces initial profile correction.'}
                    Import-Module (Join-Path $PSScriptRoot '../InitialValidationProfileClosureCorrection.psm1')
                    $correction=Test-MorphospaceHistoricalInitialValidationProfileClosure -WorkspaceRoot $workspace -ExpectedEvent $event
                    $isCorrection=$true
                    $request=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$intent.artifacts[0].bytes_base64))
                    if([string]$request.expected.source_composition.path-cne[string]$unit.source_composition.lock_path-or[string]$request.expected.source_composition.sha256-cne$files[$lockPath]){throw 'Bootstrap validation profile correction source lock is detached.'}
                }elseif($null-eq$begin-and@($intent.artifacts).Count-eq1){
                    $completion=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$intent.artifacts[0].bytes_base64))
                    Assert-BootstrapValidationSchema $completion 'work-unit-automation-receipt.schema.json'
                    if([string]$completion.action-cne'CompleteInstructionSurfaces'-or-not[bool]$completion.executed-or
                       [string]$completion.instruction_surface_completion.expected_unit_sha256-cne[string]$intent.pre.unit.sha256-or
                       [string]$completion.instruction_surface_completion.resulting_unit_sha256-cne[string]$intent.target.unit.sha256-or[string]$completion.event_id-cne[string]$event.event_id){throw 'Bootstrap validation instruction completion is detached.'}
                    foreach($surface in @($expectedUnit.instruction_surfaces)){if([string]$surface.status-ceq'planned'){$surface.status='complete'}}
                }elseif($null-ne$begin-and$null-eq$record-and[string]$event.event_id-cmatch'-validation-pass-[0-9]{4,}$'){
                    if($null-eq$Receipt-or-not$ReceiptPath-or@($intent.artifacts).Count-ne1){throw 'Bootstrap validation Record must retain exactly its consumed receipt.'}
                    $relative=ConvertTo-MorphospaceProtocolRelativePath ([string]$target.validation_checkpoint.receipt)
                    $references=@($event.receipts|ForEach-Object{[string]$_})
                    if($references.Count-ne2){throw 'Bootstrap validation Record receipt is detached.'}
                    $originalRelative=ConvertTo-MorphospaceProtocolRelativePath $references[0]
                    $directory=([string][IO.Path]::GetDirectoryName($originalRelative)).Replace('\','/')
                    $retainedName=[string]$event.event_id+'-retained-validation.json'
                    $expectedRetained=if($directory){$directory+'/'+$retainedName}else{$retainedName}
                    $retained=ConvertFrom-MorphospaceProtocolJsonBytes ([Convert]::FromBase64String([string]$intent.artifacts[0].bytes_base64))
                    Assert-BootstrapValidationSchema $retained 'validation-receipt.schema.json'
                    if($relative-cne$expectedRetained-or$references[1]-cne$expectedRetained-or$originalRelative-ceq$expectedRetained-or
                       [string]$intent.artifacts[0].path-cne$relative-or
                       [string]$target.validation_checkpoint.receipt-cne$relative-or[string]$target.validation_checkpoint.result-cne'pass'-or[string]$target.validation_checkpoint.tier-cne[string]$Receipt.tier-or
                       [string]$retained.schema-cne'rusty.morphospace.workflow.validation_receipt.v1'-or[string]$retained.project_id-cne[string]$project.project_id-or
                       [string]$retained.unit_id-cne$UnitId-or[string]$retained.tier-cne[string]$target.validation_checkpoint.tier-or[string]$retained.result-cne'pass'-or
                       [string]$intent.artifacts[0].sha256-cne$receiptRawHash-or
                       (Get-MorphospaceCanonicalJsonSha256 $retained)-cne(Get-MorphospaceCanonicalJsonSha256 $Receipt)){throw 'Bootstrap validation Record receipt is detached.'}
                    foreach($reference in $references){[void](ConvertTo-MorphospaceProtocolRelativePath $reference)}
                    $retainedReceiptPath=Resolve-MorphospaceWorkspacePath $workspace $relative -RequireLeaf
                    if(-not$accepted-and-not$retainedReceiptPath.Equals($actualReceiptPath,$script:BootstrapPathComparison)){throw 'Bootstrap validation Record receipt is detached.'}
                    $record=$step
                }elseif($null-ne$record-and-not$acceptedStep-and[string]$previousUnit.status-ceq'validating'-and[string]$event.event_id-cmatch'-accepted-[0-9]{4,}$'-and$accepted){
                    $expectedUnit.status='accepted'
                    $references=@($event.receipts|ForEach-Object{[string]$_})
                    if($references.Count-ne2-or@($intent.artifacts).Count-ne1){throw 'Bootstrap validation Accept is detached.'}
                    $recordRelative=[string]$previous.validation_checkpoint.receipt
                    $directory=([string][IO.Path]::GetDirectoryName($recordRelative)).Replace('\','/')
                    $retainedName=[string]$event.event_id+'-retained-validation.json'
                    $expectedRetained=if($directory){$directory+'/'+$retainedName}else{$retainedName}
                    $retainedReceiptPath=Resolve-MorphospaceWorkspacePath $workspace $expectedRetained -RequireLeaf
                    if($null-ne$target.current_unit-or$references[0]-cne$recordRelative-or$references[1]-cne$expectedRetained-or
                       [string]$target.last_accepted_receipt-cne$expectedRetained-or[string]$target.validation_checkpoint.receipt-cne$expectedRetained-or
                       [string]$target.validation_checkpoint.result-cne'pass'-or[string]$target.validation_checkpoint.tier-cne[string]$previous.validation_checkpoint.tier-or
                       [string]$intent.artifacts[0].path-cne$expectedRetained-or[string]$intent.artifacts[0].sha256-cne[string]$record.intent.artifacts[0].sha256-or
                       [string]$intent.artifacts[0].sha256-cne$receiptRawHash-or-not$retainedReceiptPath.Equals($actualReceiptPath,$script:BootstrapPathComparison)){throw 'Bootstrap validation Accept is detached.'}
                    $acceptedStep=$true
                }else{throw 'Bootstrap validation origin transition is unsupported.'}
                if((Get-MorphospaceCanonicalJsonSha256 $expectedUnit)-cne[string]$intent.target.unit.sha256){throw 'Bootstrap validation immutable unit differs from native origin.'}
            }
            if($null-ne$previous-and-not$isCorrection){
                # Repository observations are refreshed by ordinary automation.
                # Every other state field must retain its actual native value.
                $expectedState=Copy-BootstrapValidationValue $previous
                foreach($name in @('last_event_id','repository_heads','dirty_repositories')){$expectedState.$name=$target.$name}
                if([string]$targetUnit.status-ceq'active'-and(-not$claimed-or[string]$previousUnit.status-ceq'ready'-or[string]$intent.schema-ceq'rusty.morphospace.workflow.transition_ledger_intent.v2')){$expectedState.current_unit=[string]$targetUnit.unit_id;$expectedState.next_ready_unit=$null}
                if($null-ne$record){$expectedState.validation_checkpoint=$target.validation_checkpoint}
                if($acceptedStep){$expectedState.current_unit=$null;$expectedState.last_accepted_receipt=[string]$target.last_accepted_receipt}
                if((Get-MorphospaceCanonicalJsonSha256 $expectedState)-cne[string]$intent.target.state.sha256){throw 'Bootstrap validation origin changes unrelated state authority.'}
            }
            if($null-ne$target.pending_push_bundle-or@($target.blockers).Count-ne0-or($null-eq$record-and$null-ne$target.validation_checkpoint)-or
               (-not$acceptedStep-and$null-ne$target.last_accepted_receipt)-or($claimed-and-not$acceptedStep-and([string]$target.current_unit-cne[string]$targetUnit.unit_id-or$null-ne$target.next_ready_unit))){throw 'Bootstrap validation origin contains prior acceptance or unrelated authority.'}
            $previous=$target;$previousUnit=$targetUnit
        }
        if(-not$claimed-or$null-eq$begin-or(Get-MorphospaceCanonicalJsonSha256 $previous)-cne(Get-MorphospaceCanonicalJsonSha256 $state)-or
           (Get-MorphospaceCanonicalJsonSha256 $previousUnit)-cne(Get-MorphospaceCanonicalJsonSha256 $unit)){throw 'Bootstrap validation current unit differs from its native origin.'}
        if($accepted-and$null-eq$record){throw 'Bootstrap validation accepted endpoint lacks its native Record.'}
        $allowed=@{};foreach($row in @($unit.allowed_repositories)){if($allowed.ContainsKey([string]$row.repo_id)){throw 'Bootstrap validation unit repeats a repository.'};$allowed[[string]$row.repo_id]=$row}
        $witness=$null
        foreach($row in @($source.repositories)){
            $id=[string]$row.repo_id
            if($baseByRepo.ContainsKey($id)-or-not$mapByRepo.ContainsKey($id)-or@($project.repositories|Where-Object{[string]$_.repo_id-ceq$id}).Count-ne1){throw 'Bootstrap validation source repository identity is missing or repeated.'}
            $mapped=$mapByRepo[$id]
            if([string]$mapped.role-cne[string]$row.role){throw 'Bootstrap validation repository map role differs from source lock.'}
            $root=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath ([string]$mapped.path)).Path).TrimEnd('\','/')
            $observed=Get-BootstrapValidationGitObservation $root;$repositories+=,$observed
            if((Invoke-BootstrapValidationGit $root @('rev-parse',"$([string]$row.commit)^{tree}")).text.Trim()-cne[string]$row.tree){throw 'Bootstrap validation locked Git tree is detached.'}
            if([IO.Path]::GetFileName($root)-cne[string]$row.materialization_path){throw 'Bootstrap validation mapped materialization differs from source lock.'}
            if($allowed.ContainsKey($id)){
                if((Invoke-BootstrapValidationGit $root @('merge-base','--is-ancestor',[string]$row.commit,[string]$observed.head) -AllowFailure).exit_code-ne0){throw 'Bootstrap validation source is not a descendant of its locked baseline.'}
                if([string]$mapped.role-cne'planning'-and$observed.status.Length-ne0){throw 'Bootstrap validation product source must be committed and clean.'}
                $paths=(Invoke-BootstrapValidationGit $root @('diff','--name-only','--no-renames','-z',[string]$row.commit,'--')).text+
                       (Invoke-BootstrapValidationGit $root @('ls-files','--others','--exclude-standard','-z')).text
                foreach($path in @($paths.Split([char]0)|Where-Object{$_})){if(-not(Test-BootstrapValidationPath $path @($allowed[$id].allowed_paths))){throw "Bootstrap validation source change is outside unit scope: ${id}:$path"}}
            }elseif($observed.head-cne[string]$row.commit-or$observed.tree-cne[string]$row.tree-or$observed.status.Length-ne0){throw 'Bootstrap validation read-only dependency differs from its exact lock.'}
            $baseByRepo[$id]=[string]$row.commit
            $prefix=$root+[IO.Path]::DirectorySeparatorChar
            if($null-eq$correction-and[string]$mapped.role-ceq'planning'-and$workspace.StartsWith($prefix,$script:BootstrapPathComparison)){
                if($null-ne$witness){throw 'Bootstrap validation planning lock witness is ambiguous.'}
                $heads=@($begin.intent.target.state.document.repository_heads|Where-Object{[string]$_.repo_id-ceq$id})
                if($heads.Count-ne1){throw 'Bootstrap validation source lock has no immutable native witness.'}
                $relative=[IO.Path]::GetRelativePath($root,$lockPath).Replace('\','/')
                $blob=(Invoke-BootstrapValidationGit $root @('rev-parse',('{0}:{1}'-f[string]$heads[0].head,$relative)) -AllowFailure)
                $physical=(Invoke-BootstrapValidationGit $root @('hash-object','--no-filters','--',$lockPath)).text.Trim()
                $entry=(Invoke-BootstrapValidationGit $root @('ls-tree',[string]$heads[0].head,'--',$relative)).text
                if($blob.exit_code-ne0-or$blob.text.Trim()-cne$physical-or$entry-cnotmatch'^(100644|100755) blob [0-9a-f]{40}\t'-or
                   (Invoke-BootstrapValidationGit $root @('merge-base','--is-ancestor',[string]$heads[0].head,[string]$observed.head) -AllowFailure).exit_code-ne0){throw 'Bootstrap validation source lock has no immutable native witness.'}
                $witness=[pscustomobject]@{repo_id=$id;commit=[string]$heads[0].head;path=$relative;blob=$physical}
            }
        }
        foreach($id in $allowed.Keys){if(-not$baseByRepo.ContainsKey($id)){throw 'Bootstrap validation lock omits a writable repository.'}}
        if($null-eq$witness-and$null-eq$correction){throw 'Bootstrap validation source lock has no immutable native witness.'}
        $artifacts=@(
            [pscustomobject]@{artifact_id='bootstrap-source-lock';kind='bootstrap-source-lock';path=$lockPath;sha256=$files[$lockPath]},
            [pscustomobject]@{artifact_id='bootstrap-repository-map';kind='bootstrap-repository-map';path=$mapPath;sha256=$files[$mapPath]},
            [pscustomobject]@{artifact_id='bootstrap-begin-intent';kind='bootstrap-begin-intent';path=$begin.intent_path;sha256=$files[$begin.intent_path]}
        )
        if($null-ne$Receipt){
            foreach($expected in $artifacts){
                $matches=@($Receipt.artifacts|Where-Object{[string]$_.artifact_id-ceq[string]$expected.artifact_id})
                if($matches.Count-ne1){throw 'Bootstrap validation reserved artifact binding is missing or detached.'}
                $actual=$matches[0];$path=if([IO.Path]::IsPathRooted([string]$actual.path)){[IO.Path]::GetFullPath([string]$actual.path)}else{[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ReceiptPath) ([string]$actual.path)))}
                if(-not$path.Equals([string]$expected.path,$script:BootstrapPathComparison)-or[string]$actual.kind-cne[string]$expected.kind-or[string]$actual.sha256-cne[string]$expected.sha256){throw 'Bootstrap validation reserved artifact binding is missing or detached.'}
            }
            $revisions=@{};foreach($revision in @($Receipt.repository_revisions)){if($revisions.ContainsKey([string]$revision.repo_id)){throw 'Bootstrap validation receipt repeats a repository.'};$revisions[[string]$revision.repo_id]=$revision}
            if($revisions.Count-ne$allowed.Count){throw 'Bootstrap validation receipt repository set differs from writable scope.'}
            foreach($id in $allowed.Keys){if(-not$revisions.ContainsKey($id)-or[string]$revisions[$id].base_revision-cne[string]$baseByRepo[$id]){throw 'Bootstrap validation repository base differs from exact source lock.'}}
        }
        $authority=[pscustomobject]@{project_id=[string]$project.project_id;unit_id=$UnitId;base_by_repo=$baseByRepo;artifacts=$artifacts;recheck_files=$files;repository_observations=$repositories;begin_transaction_id=[string]$begin.intent.transaction_id;begin_intent_path=$begin.intent_path;lock_witness=$witness;retained_receipt_path=$retainedReceiptPath}
        Assert-MorphospaceBootstrapValidationObservation $authority
        return $authority
    }finally{Exit-MorphospaceWorkspaceMutex $mutex}
}
Export-ModuleMember -Function Get-MorphospaceBootstrapValidationAuthority,Assert-MorphospaceBootstrapValidationObservation
