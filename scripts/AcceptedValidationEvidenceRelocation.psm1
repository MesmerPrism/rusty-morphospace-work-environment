Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceContentObservation.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceTransitionLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceValidationReceipt.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceCurrentWorkCompatibility.psm1')

function Get-RelocationWorkspacePath([string]$Workspace,[string]$Relative,[switch]$RequireLeaf) {
    $path=Resolve-MorphospaceWorkspacePath $Workspace $Relative -RequireLeaf:$RequireLeaf
    $root=[IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')
    $current=$root
    foreach($part in $Relative.Split('/')) {
        $current=Join-Path $current $part
        if(-not(Test-Path -LiteralPath $current)){continue}
        if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint)-ne0){throw "Evidence relocation path traverses a reparse point: $Relative"}
    }
    return $path
}
function Get-RelocationGitContext([string]$Workspace) {
    $git=Get-MorphospaceBoundExecutable -Name 'git'
    if($IsWindows-and[IO.Path]::GetExtension([string]$git.path).ToLowerInvariant()-cne'.exe'){throw 'Relocation Git must be a bound executable, not a shell wrapper.'}
    $result=Invoke-MorphospaceBoundProcessBytes -Executable $git.path -Arguments @('-C',$Workspace,'rev-parse','--show-toplevel') -WorkingDirectory $Workspace -ExpectedExecutableSha256 $git.sha256 -TimeoutSeconds 30 -MaxOutputBytes 1048576
    $root=[IO.Path]::GetFullPath(([Text.UTF8Encoding]::new($false,$true).GetString($result.stdout)).Trim()).TrimEnd('\','/')
    return [pscustomobject]@{executable=$git.path;sha256=$git.sha256;root=$root}
}
function Invoke-RelocationGit([object]$Git,[string[]]$Arguments) {
    Invoke-MorphospaceBoundProcessBytes -Executable $Git.executable -Arguments (@('-C',[string]$Git.root)+$Arguments) -WorkingDirectory $Git.root -ExpectedExecutableSha256 $Git.sha256 -TimeoutSeconds 30 -MaxOutputBytes 1048576 -AllowFailure
}
function Get-RelocationGitRelative([string]$Workspace,[string]$Path,[object]$Git) {
    $full=Get-RelocationWorkspacePath $Workspace $Path -RequireLeaf
    $relative=[IO.Path]::GetRelativePath([string]$Git.root,$full).Replace('\','/')
    if($relative.StartsWith('../',[StringComparison]::Ordinal)-or$relative-ceq'..'){throw 'Evidence path leaves the planning owner.'}
    return $relative
}
function Assert-RelocationUntracked([string]$Workspace,[string]$Path,[object]$Git,[string]$Context) {
    $relative=Get-RelocationGitRelative $Workspace $Path $Git
    $tracked=Invoke-RelocationGit $Git @('ls-files','--error-unmatch','--',$relative)
    if($tracked.exit_code-eq0){throw "$Context is tracked by the planning owner."}
    if($tracked.exit_code-ne1){throw "Could not establish $Context tracked state."}
    $historical=Invoke-RelocationGit $Git @('log','--all','-1','--format=%H','--',$relative)
    if($historical.exit_code-ne0){throw "Could not establish $Context planning history."}
    if($historical.stdout.Length-gt0){throw "$Context is tracked in planning Git history."}
    return $relative
}
function Assert-RelocationLocalIgnored([string]$Workspace,[string]$LocalPath) {
    if($LocalPath-cnotmatch'^local/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$'){throw 'Relocated evidence must use a canonical workspace-local path.'}
    $git=Get-RelocationGitContext $Workspace
    $relative=Assert-RelocationUntracked $Workspace $LocalPath $git 'Relocated evidence'
    $ignored=Invoke-RelocationGit $git @('check-ignore','-q','--',$relative)
    if($ignored.exit_code-ne0){throw 'Relocated evidence is not ignored by the planning owner.'}
    return Get-RelocationWorkspacePath $Workspace $LocalPath -RequireLeaf
}
function Assert-RelocationOriginalUntracked([string]$Workspace,[string]$OriginalPath) {
    $git=Get-RelocationGitContext $Workspace
    [void](Assert-RelocationUntracked $Workspace $OriginalPath $git 'Original accepted evidence')
}
function Read-RelocationEvents([string]$Workspace) {
    $path=Get-RelocationWorkspacePath $Workspace 'iteration-events.jsonl' -RequireLeaf
    return @([IO.File]::ReadAllLines($path) | Where-Object {$_} | ForEach-Object {$_|ConvertFrom-Json -Depth 100 -DateKind String})
}
function Get-RelocationAcceptance([string]$Workspace,[object]$Document,[switch]$AllowIncompleteSuccessor) {
    $events=Read-RelocationEvents $Workspace
    $accepted=@($events|Where-Object{[string]$_.event_id-ceq[string]$Document.acceptance.event_id})
    if($accepted.Count-ne1-or[string]$accepted[0].unit_id-cne[string]$Document.unit_id-or
       [string]$accepted[0].event_id-cnotmatch('^'+[regex]::Escape([string]$Document.unit_id)+'-accepted-[0-9]{4,}$')-or
       @($accepted[0].receipts).Count-ne1-or[string]$accepted[0].receipts[0]-cne[string]$Document.acceptance.receipt_path){
        throw 'Evidence relocation does not name one exact accepted predecessor.'
    }
    $event=$accepted[0];$id="$([string]$event.event_id)-transition"
    $intentPath=Get-RelocationWorkspacePath $Workspace "receipts/transactions/$id.intent.json" -RequireLeaf
    $completionPath=Get-RelocationWorkspacePath $Workspace "receipts/transactions/$id.completion.json" -RequireLeaf
    $receiptPath=Get-RelocationWorkspacePath $Workspace ([string]$Document.acceptance.receipt_path) -RequireLeaf
    if((Get-MorphospaceFileSha256 $intentPath)-cne[string]$Document.acceptance.intent_sha256-or
       (Get-MorphospaceFileSha256 $completionPath)-cne[string]$Document.acceptance.completion_sha256-or
       (Get-MorphospaceFileSha256 $receiptPath)-cne[string]$Document.acceptance.receipt_sha256){
        throw 'Evidence relocation accepted checkpoint bytes drifted.'
    }
    $proof=if($AllowIncompleteSuccessor){$null}else{Test-MorphospaceAcceptedCheckpointProof -WorkspaceRoot $Workspace -ExpectedEvent $event -AllowFiniteHistoricalV1}
    $receipt=Assert-MorphospaceValidationReceiptStructure -ReceiptPath $receiptPath -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1'
    if([string]$receipt.result-cne'pass'-or[string]$receipt.unit_id-cne[string]$Document.unit_id-or
       [string]$receipt.project_id-cne[string]$Document.project_id){throw 'Evidence relocation is detached from the passing accepted receipt.'}
    return [pscustomobject]@{event=$event;proof=$proof;receipt=$receipt;receipt_path=$receiptPath;events=$events}
}
function Assert-RelocationDocument([string]$Workspace,[object]$Document,[string]$DocumentPath,[switch]$RequireOriginal,[switch]$AllowIncompleteSuccessor) {
    $repoRoot=Split-Path $PSScriptRoot -Parent
    if(-not(Test-Json -Json (Get-Content -Raw -LiteralPath $DocumentPath) -SchemaFile (Join-Path $repoRoot 'schemas/accepted-validation-evidence-relocation-v1.schema.json'))){
        throw 'Accepted evidence relocation does not satisfy its schema.'
    }
    $acceptance=Get-RelocationAcceptance $Workspace $Document -AllowIncompleteSuccessor:$AllowIncompleteSuccessor
    $createdAt=[string]$Document.created_at
    if($createdAt-cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$'-or
       (ConvertFrom-MorphospaceInvariantTimestamp $createdAt)-lt(ConvertFrom-MorphospaceInvariantTimestamp ([string]$acceptance.event.timestamp))){
        throw 'Relocation timestamp must be UTC and no earlier than acceptance.'
    }
    $eventId=[string]$Document.relocation_id
    if($eventId-cne"$([string]$Document.unit_id)-accepted-evidence-relocated-$('{0:d4}' -f ([int]$acceptance.event.sequence+1))"){
        throw 'Accepted evidence relocation event identity is not canonical.'
    }
    $rows=@($Document.artifacts)
    $receiptRows=@($acceptance.receipt.artifacts)
    if($rows.Count-ne$receiptRows.Count){throw 'Accepted evidence relocation must cover every accepted artifact exactly once.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for($i=0;$i-lt$rows.Count;$i++){
        $row=$rows[$i];$original=$receiptRows[$i]
        $source=[string]$original.path
        if([IO.Path]::IsPathRooted($source)-or$source-cnotmatch'^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$'){throw 'Relocation supports only portable receipt-relative artifact paths.'}
        $originalFull=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $acceptance.receipt_path) $source))
        $originalRelative=[IO.Path]::GetRelativePath($Workspace,$originalFull).Replace('\','/')
        if(-not$ids.Add([string]$row.artifact_id)-or-not$paths.Add([string]$row.local_path)-or
           [string]$row.artifact_id-cne[string]$original.artifact_id-or
           [string]$row.original_path-cne$originalRelative-or
           [string]$row.sha256-cne([string]$original.sha256).ToLowerInvariant()){
            throw 'Relocation artifact order, identity, path, or hash differs from the immutable receipt.'
        }
        $localFull=Assert-RelocationLocalIgnored $Workspace ([string]$row.local_path)
        if((Get-MorphospaceFileSha256 $localFull)-cne[string]$row.sha256){throw 'Relocated local evidence hash drifted.'}
        if($RequireOriginal-or(Test-Path -LiteralPath $originalFull -PathType Leaf)){
            $originalFull=Get-RelocationWorkspacePath $Workspace $originalRelative -RequireLeaf
            Assert-RelocationOriginalUntracked $Workspace $originalRelative
        }
        if($RequireOriginal){
            if((Get-MorphospaceFileSha256 $originalFull)-cne[string]$row.sha256){throw 'Original accepted evidence hash drifted before relocation.'}
        }
    }
    return $acceptance
}
function Test-MorphospaceAcceptedEvidenceRelocation {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RelocationId,[switch]$RequireTail)
    $workspace=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path)
    if($RelocationId-cnotmatch'^[a-z0-9][a-z0-9-]{1,127}$'){throw 'Relocation identity is invalid.'}
    $relative="receipts/$RelocationId.json";$path=Get-RelocationWorkspacePath $workspace $relative -RequireLeaf
    $document=Read-MorphospaceProtocolJson $path
    $acceptance=Assert-RelocationDocument $workspace $document $path
    $matching=@($acceptance.events|Where-Object{[string]$_.event_id-ceq$RelocationId})
    if($matching.Count-ne1-or[int]$matching[0].sequence-ne([int]$acceptance.event.sequence+1)-or
       [string]$matching[0].unit_id-cne[string]$document.unit_id-or
       [string]$matching[0].project_id-cne[string]$document.project_id-or
       [string]$matching[0].event_type-cne'state-transition'-or
       [string]$matching[0].summary-cne'Relocated exact accepted validation artifacts into ignored local evidence without changing acceptance.'-or
       @($matching[0].receipts).Count-ne1-or[string]$matching[0].receipts[0]-cne$relative-or
       [string]$matching[0].timestamp-cne[string]$document.created_at){throw 'Accepted evidence relocation event is detached.'}
    $step=Test-MorphospaceCommittedTransitionLedger -WorkspaceRoot $workspace -TransactionId "$RelocationId-transition" -ExpectedStatePath 'workspace.state.json' -ExpectedUnitPath "iteration-units/$([string]$document.unit_id).json" -ExpectedEventsPath 'iteration-events.jsonl' -RequireTail:$RequireTail
    $intent=$step.intent
    $target=$acceptance.proof.intent.target.state.document|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
    $target.last_event_id=$RelocationId
    if([string]$intent.schema-cne'rusty.morphospace.workflow.transition_ledger_intent.v1'-or
       [string]$intent.expected.event_tail_id-cne[string]$acceptance.event.event_id-or
       [string]$intent.pre.state.sha256-cne[string]$acceptance.proof.intent.target.state.sha256-or
       [string]$intent.pre.unit.sha256-cne[string]$acceptance.proof.intent.target.unit.sha256-or
       [string]$intent.target.unit.sha256-cne[string]$intent.pre.unit.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $intent.target.state.document)-cne(Get-MorphospaceCanonicalJsonSha256 $target)-or
       @($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].path-cne$relative-or
       [string]$intent.artifacts[0].sha256-cne(Get-MorphospaceFileSha256 $path)-or
       (Get-MorphospaceCanonicalJsonSha256 $intent.event)-cne(Get-MorphospaceCanonicalJsonSha256 $matching[0])){
        throw 'Accepted evidence relocation transaction changes or detaches accepted authority.'
    }
    return [pscustomobject]@{document=$document;event=$matching[0];acceptance_event=$acceptance.event;step=$step;receipt_path=$path}
}
function New-MorphospaceAcceptedEvidenceRelocationInput {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$UnitId,[Parameter(Mandatory)][string]$LocalDirectory,[Parameter(Mandatory)][string]$CreatedAt,[Parameter(Mandatory)][string]$OutPath)
    $workspace=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path)
    $state=Read-MorphospaceProtocolJson (Get-RelocationWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    $unit=Read-MorphospaceProtocolJson (Get-RelocationWorkspacePath $workspace "iteration-units/$UnitId.json" -RequireLeaf)
    $events=Read-RelocationEvents $workspace;$accepted=$events[-1]
    if([string]$unit.status-cne'accepted'-or$null-ne$state.current_unit-or$null-ne$state.pending_push_bundle-or
       [string]$state.last_event_id-cne[string]$accepted.event_id-or
       [string]$accepted.event_id-cnotmatch('^'+[regex]::Escape($UnitId)+'-accepted-[0-9]{4,}$')-or
       [string]$state.last_accepted_receipt-cne[string]$accepted.receipts[0]){throw 'Relocation requires the exact idle accepted event tail.'}
    $receiptRelative=[string]$accepted.receipts[0];$receiptPath=Get-RelocationWorkspacePath $workspace $receiptRelative -RequireLeaf
    $receipt=Assert-MorphospaceValidationReceiptStructure -ReceiptPath $receiptPath -AllowedSchemaIds 'rusty.morphospace.workflow.validation_receipt.v1'
    $localPrefix=$LocalDirectory.TrimEnd('/')
    if($localPrefix-cnotmatch'^local/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$'){throw 'Local evidence directory must be under ignored local/.'}
    $rows=@();foreach($artifact in @($receipt.artifacts)){
        $source=[string]$artifact.path
        if([IO.Path]::IsPathRooted($source)-or$source-cnotmatch'^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$'){throw 'Relocation requires portable receipt-relative artifact paths.'}
        $original=[IO.Path]::GetRelativePath($workspace,[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $receiptPath) $source))).Replace('\','/')
        $rows+=,[pscustomobject][ordered]@{artifact_id=[string]$artifact.artifact_id;original_path=$original;local_path="$localPrefix/$([IO.Path]::GetFileName($source))";sha256=([string]$artifact.sha256).ToLowerInvariant()}
    }
    $id="$UnitId-accepted-evidence-relocated-$('{0:d4}' -f ([int]$accepted.sequence+1))"
    $tx="$([string]$accepted.event_id)-transition"
    $doc=[pscustomobject][ordered]@{
        schema='rusty.morphospace.workflow.accepted_validation_evidence_relocation.v1';relocation_id=$id;project_id=[string]$state.project_id;unit_id=$UnitId;created_at=$CreatedAt
        acceptance=[pscustomobject][ordered]@{event_id=[string]$accepted.event_id;intent_sha256=(Get-MorphospaceFileSha256 (Get-RelocationWorkspacePath $workspace "receipts/transactions/$tx.intent.json" -RequireLeaf));completion_sha256=(Get-MorphospaceFileSha256 (Get-RelocationWorkspacePath $workspace "receipts/transactions/$tx.completion.json" -RequireLeaf));receipt_path=$receiptRelative;receipt_sha256=(Get-MorphospaceFileSha256 $receiptPath)}
        artifacts=@($rows);preservation=[pscustomobject][ordered]@{accepted_receipt_unchanged=$true;accepted_event_prefix_unchanged=$true;validation_reexecuted=$false;source_published=$false}
    }
    $out=[IO.Path]::GetFullPath($OutPath)
    if(Test-Path -LiteralPath $out){throw 'Relocation input already exists.'}
    try {
        [IO.File]::WriteAllText($out,(($doc|ConvertTo-Json -Depth 40)+"`n"),[Text.UTF8Encoding]::new($false))
        [void](Assert-RelocationDocument $workspace $doc $out -RequireOriginal)
    } catch {
        if(Test-Path -LiteralPath $out){Remove-Item -LiteralPath $out -Force}
        throw
    }
    return [pscustomobject]@{path=$out;sha256=(Get-MorphospaceFileSha256 $out);relocation_id=$id}
}
function Invoke-MorphospaceRelocateAcceptedValidationEvidence {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RelocationInput,[Parameter(Mandatory)][string]$ExpectedInputSha256,[Parameter(Mandatory)][string]$OutPath,[switch]$Execute,[ValidateSet('none','after-intent','after-artifact','after-projection','after-event')][string]$FaultAfter='none')
    $workspace=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path)
    $input=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RelocationInput).Path)
    $hash=Get-MorphospaceFileSha256 $input
    if($hash-cne$ExpectedInputSha256){throw 'Expected accepted evidence relocation input hash differs.'}
    $doc=Read-MorphospaceProtocolJson $input
    $id=[string]$doc.relocation_id;$relative="receipts/$id.json"
    $out=Get-RelocationWorkspacePath $workspace $relative
    if([IO.Path]::GetFullPath($OutPath)-cne$out){throw 'Relocation output must use the canonical receipt path.'}
    $intentPath=Get-RelocationWorkspacePath $workspace "receipts/transactions/$id-transition.intent.json"
    if(Test-Path -LiteralPath $intentPath){
        if(-not$Execute){throw 'Interrupted relocation requires exact Execute recovery.'}
        $intent=Read-MorphospaceProtocolJson $intentPath
        if(@($intent.artifacts).Count-ne1-or[string]$intent.artifacts[0].path-cne$relative-or
           [string]$intent.artifacts[0].sha256-cne$hash-or
           [string]$intent.artifacts[0].bytes_base64-cne[Convert]::ToBase64String([IO.File]::ReadAllBytes($input))-or
           [string]$intent.event.event_id-cne$id){
            throw 'Interrupted relocation input differs from its immutable transaction.'
        }
        [void](Assert-RelocationDocument $workspace $doc $input -AllowIncompleteSuccessor)
        [void](Complete-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$id-transition" -Repair -FaultAfter $FaultAfter)
        $result=Test-MorphospaceAcceptedEvidenceRelocation -WorkspaceRoot $workspace -RelocationId $id -RequireTail
        return [pscustomobject]@{relocation_id=$id;receipt_path=$relative;sha256=(Get-MorphospaceFileSha256 $result.receipt_path);executed=$true;recovered=$true}
    }
    $accepted=Assert-RelocationDocument $workspace $doc $input -RequireOriginal
    $state=Read-MorphospaceProtocolJson (Get-RelocationWorkspacePath $workspace 'workspace.state.json' -RequireLeaf)
    $unit=Read-MorphospaceProtocolJson (Get-RelocationWorkspacePath $workspace "iteration-units/$([string]$doc.unit_id).json" -RequireLeaf)
    if([string]$unit.status-cne'accepted'-or$null-ne$state.current_unit-or$null-ne$state.pending_push_bundle-or
       [string]$state.last_event_id-cne[string]$accepted.event.event_id-or
       [string]$state.last_accepted_receipt-cne[string]$doc.acceptance.receipt_path-or
       (Get-MorphospaceCanonicalJsonSha256 $state)-cne[string]$accepted.proof.intent.target.state.sha256-or
       (Get-MorphospaceCanonicalJsonSha256 $unit)-cne[string]$accepted.proof.intent.target.unit.sha256){
        throw 'Relocation requires the unchanged idle accepted state and unit.'
    }
    if(Test-Path -LiteralPath $out){throw 'Relocation receipt target already exists.'}
    $target=$state|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String;$target.last_event_id=$id
    $event=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.iteration_event.v1';event_id=$id;sequence=[int]$accepted.event.sequence+1;timestamp=[string]$doc.created_at;project_id=[string]$doc.project_id;unit_id=[string]$doc.unit_id;event_type='state-transition';summary='Relocated exact accepted validation artifacts into ignored local evidence without changing acceptance.';receipts=@($relative)}
    if($Execute){
        [void](Start-MorphospaceTransitionLedger -WorkspaceRoot $workspace -TransactionId "$id-transition" -StatePath 'workspace.state.json' -UnitPath "iteration-units/$([string]$doc.unit_id).json" -EventsPath 'iteration-events.jsonl' -TargetState $target -TargetUnit $unit -Event $event -ExpectedStateSha256 (Get-MorphospaceCanonicalJsonSha256 $state) -ExpectedUnitSha256 (Get-MorphospaceCanonicalJsonSha256 $unit) -ExpectedEventTailId ([string]$accepted.event.event_id) -ExpectedEventsSha256 (Get-MorphospaceFileSha256 (Get-RelocationWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf)) -ExpectedEventsLength ([IO.FileInfo](Get-RelocationWorkspacePath $workspace 'iteration-events.jsonl' -RequireLeaf)).Length -Artifacts @([pscustomobject]@{source_path=$input;path=$relative;sha256=$hash}) -FaultAfter $FaultAfter)
        [void](Test-MorphospaceAcceptedEvidenceRelocation -WorkspaceRoot $workspace -RelocationId $id -RequireTail)
    }
    return [pscustomobject]@{relocation_id=$id;receipt_path=$relative;sha256=$hash;executed=$Execute.IsPresent;recovered=$false}
}
Export-ModuleMember -Function New-MorphospaceAcceptedEvidenceRelocationInput,Invoke-MorphospaceRelocateAcceptedValidationEvidence,Test-MorphospaceAcceptedEvidenceRelocation
