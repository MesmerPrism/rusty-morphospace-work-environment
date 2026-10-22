[CmdletBinding(DefaultParameterSetName = 'verify')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$RepositoryRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$BeforeCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'verify')][string]$HeadCommit,
    [Parameter(Mandatory = $true, ParameterSetName = 'self')][switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Get-WorkflowStatusGuardOutcome([string]$Status, [bool]$Cancelled, [bool]$PriorFailure) {
    switch -CaseSensitive ($Status) {
        '!cancelled()' { return -not $Cancelled }
        'always()' { return $true }
        'success()' { return (-not $Cancelled -and -not $PriorFailure) }
        default { throw "Unsupported workflow status guard '$Status'." }
    }
}
function Assert-CancellationAwareCondition([string]$Body, [int]$Indent, [string]$Label) {
    $pattern = '(?m)^' + (' ' * $Indent) + 'if:\s+\$\{\{\s*(?<status>!?[a-z]+\(\))\s+&&'
    $matches = [regex]::Matches($Body, $pattern)
    if ($matches.Count -ne 1) { throw "Validate workflow $Label must have exactly one explicit status guard." }
    $status = $matches[0].Groups['status'].Value
    if (Get-WorkflowStatusGuardOutcome -Status $status -Cancelled $true -PriorFailure $false) { throw "Validate workflow $Label remains eligible after cancellation." }
    if (-not (Get-WorkflowStatusGuardOutcome -Status $status -Cancelled $false -PriorFailure $true)) { throw "Validate workflow $Label does not preserve ordinary failure handling." }
}
function Assert-TopologyClosedTokens([string]$Expected,[string]$Observed) {
    $tokenSets=@()
    foreach($text in @($Expected,$Observed)) {
        $policyTokens=$null;$policyErrors=$null
        [void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$policyTokens,[ref]$policyErrors)
        if($policyErrors.Count){throw 'Validate workflow timeout contract does not parse.'}
        $tokenSets+=,@($policyTokens|Where-Object{$_.Kind -notin @('Comment','NewLine','EndOfInput')})
    }
    if($tokenSets[0].Count-ne$tokenSets[1].Count){throw 'Validate workflow timeout contract has unexpected statements.'}
    for($index=0;$index-lt$tokenSets[0].Count;$index++) {
        if($tokenSets[0][$index].Kind-ne$tokenSets[1][$index].Kind-or$tokenSets[0][$index].Text-cne$tokenSets[1][$index].Text){throw 'Validate workflow timeout contract differs from its closed advisory policy.'}
    }
}
function Assert-AdvisoryWorkflowJobTimeout([string]$Workflow) {
    # Inspect the actual selector script AST, so comments and quoted decoys
    # cannot stand in for the real helper or matrix assignment.
    $steps=[regex]::Matches($Workflow,'(?ms)^      - name: Resolve exact affected-validation plan\r?\n(?<body>.*?)(?=^      - |\z)')
    if($steps.Count-ne1){throw 'Validate workflow selector step is not unique.'}
    $run=[regex]::Match($steps[0].Groups['body'].Value,'(?ms)^        run: \|\r?\n(?<code>.*)\z')
    if(-not$run.Success){throw 'Validate workflow selector script is missing.'}
    $lines=@($run.Groups['code'].Value -split '\r?\n')
    $source=(@(foreach($line in $lines){if($line.Length){if(-not$line.StartsWith('          ',[StringComparison]::Ordinal)){throw 'Validate workflow selector script indentation differs.'};$line.Substring(10)}})-join"`n")
    $selectorTokens=$null;$selectorErrors=$null
    $selectorAst=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$selectorTokens,[ref]$selectorErrors)
    if($selectorErrors.Count){throw 'Validate workflow selector script does not parse.'}
    $helpers=@($selectorAst.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and[StringComparer]::OrdinalIgnoreCase.Equals(($node.Name-split':')[-1],'Get-AffectedJobTimeoutMinutes')},$true))
    $includes=@($selectorAst.FindAll({param($node) $node-is[Management.Automation.Language.AssignmentStatementAst]-and$node.Left-is[Management.Automation.Language.VariableExpressionAst]-and[StringComparer]::OrdinalIgnoreCase.Equals(($node.Left.VariablePath.UserPath-split':')[-1],'include')},$true))
    if($helpers.Count-ne1-or$includes.Count-ne1){throw 'Validate workflow executable helper/matrix assignment is not unique.'}
    # Ordinary attestation inspects caller repository source without executing it.
    # Compare a closed token contract; whitespace/comments do not add authority.
    $expected = @'
function Get-AffectedJobTimeoutMinutes([long]$EstimatedBudgetSeconds) {
  if ([Math]::Ceiling(($EstimatedBudgetSeconds + 900) / 60.0) -ge 360) {
    try { Write-Warning 'Estimated segment cost reaches the configured platform ceiling; inspect progress and retain the original job.' } catch { }
  }
  return 360
}
'@
    Assert-TopologyClosedTokens $expected $helpers[0].Extent.Text
    $expectedMatrix = @'
$include = if ($segments.Count -eq 0) { @([pscustomobject][ordered]@{segment_id="$platform-000";timeout_minutes=360}) } else { @($segments | ForEach-Object { [pscustomobject][ordered]@{segment_id=[string]$_.segment_id;timeout_minutes=(Get-AffectedJobTimeoutMinutes -EstimatedBudgetSeconds ([long]$_.estimated_budget_seconds))} }) }
'@
    Assert-TopologyClosedTokens $expectedMatrix $includes[0].Extent.Text
}
function Get-TopologyStepSource([string]$Body,[string]$Name) {
    $steps=[regex]::Matches($Body,'(?ms)^      - name: '+[regex]::Escape($Name)+'\r?\n(?<body>.*?)(?=^      - |\z)')
    if($steps.Count-ne1){throw "Linux direct workflow step is missing or duplicate: $Name"}
    $run=[regex]::Match($steps[0].Groups['body'].Value,'(?ms)^        run: \|\r?\n(?<code>.*)\z')
    if(-not$run.Success){throw "Linux direct workflow step has no literal script: $Name"}
    return (@(foreach($line in @($run.Groups['code'].Value -split '\r?\n')){if($line.Length){if(-not$line.StartsWith('          ',[StringComparison]::Ordinal)){throw 'Linux direct workflow script indentation changed.'};$line.Substring(10)}})-join"`n")
}
function Get-TopologyWorkflowExecutorCalls([string]$Body) {
    $runs=[regex]::Matches($Body,'(?ms)^        run: (?:\|\r?\n(?<block>.*?)(?=^      - |\z)|(?<inline>[^\r\n]+))')
    if($runs.Count-ne([regex]::Matches($Body,'(?m)^        run:')).Count){throw 'Linux workflow contains an unsupported run-script shape.'}
    $allCalls=[Collections.Generic.List[object]]::new()
    foreach($run in $runs) {
        $source=if($run.Groups['inline'].Success){$run.Groups['inline'].Value}else{(@(foreach($line in @($run.Groups['block'].Value-split'\r?\n')){if($line.Length){if(-not$line.StartsWith('          ',[StringComparison]::Ordinal)){throw 'Linux workflow script indentation changed.'};$line.Substring(10)}})-join"`n")}
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Linux workflow run script does not parse.'}
        foreach($call in @($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$null-ne$node.GetCommandName()-and$node.GetCommandName()-match'(?i)(?:^|[/\\])Invoke-AffectedValidation\.ps1$'},$true))){$allCalls.Add($call)}
    }
    return [pscustomobject]@{run_count=$runs.Count;calls=@($allCalls)}
}
function Assert-TopologyLinuxDirectJob([string]$Body,[string]$StepName) {
    if($Body-match'(?m)^    (?:strategy|matrix):'-or$Body.Contains('-SegmentId')){throw 'Linux direct workflow cannot partition execution across runner parents.'}
    $jobCalls=Get-TopologyWorkflowExecutorCalls $Body
    if($jobCalls.run_count-ne2-or$jobCalls.calls.Count-ne1){throw 'Linux direct workflow requires exactly two known run steps and one actual executor across the whole job.'}
    $source=Get-TopologyStepSource $Body $StepName
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Linux direct workflow execution script does not parse.'}
    $calls=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$null-ne$node.GetCommandName()-and$node.GetCommandName()-match'(?i)(?:^|[/\\])Invoke-AffectedValidation\.ps1$'},$true))
    $expected=@'
& ./scripts/Invoke-AffectedValidation.ps1 -RepositoryRoot . -BaseCommit $base -HeadCommit $head -PlanPath "$env:RUNNER_TEMP/affected-plan.json" -Platform linux -OutPath $evidencePath -CheckEvidenceDirectory $currentRoot -PriorEvidenceDirectory $priorRoot
'@
    if($calls.Count-ne1){throw 'Linux direct workflow requires exactly one actual whole-platform executor call.'}
    Assert-TopologyClosedTokens $expected $calls[0].Extent.Text
    foreach($binding in @(
        @('base', '$base = if ($env:GITHUB_EVENT_NAME -ceq ''pull_request'') { $env:PR_BASE } elseif ($env:GITHUB_EVENT_NAME -ceq ''push'') { $env:PUSH_BEFORE } else { (git rev-parse HEAD^).Trim() }'),
        @('head', '$head = if ($env:GITHUB_EVENT_NAME -ceq ''pull_request'') { $env:PR_HEAD } else { $env:GITHUB_SHA }'),
        @('tier', '$tier = if ($env:GITHUB_EVENT_NAME -cin @(''schedule'',''workflow_dispatch'')) { ''Deep'' } else { ''Quick'' }'),
        @('selected', '$selected = @($plan.selected_checks | Where-Object { @($_.platforms) -ccontains ''linux'' })')
    )) {
        $assignments=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.AssignmentStatementAst]-and$node.Left-is[Management.Automation.Language.VariableExpressionAst]-and[StringComparer]::OrdinalIgnoreCase.Equals(($node.Left.VariablePath.UserPath-split':')[-1],[string]$binding[0])},$true))
        if($assignments.Count-ne1){throw "Linux direct workflow event/selection binding is not exact: $($binding[0])"}
        Assert-TopologyClosedTokens $binding[1] $assignments[0].Extent.Text
    }
    foreach($required in @('execution_permitted','selected.Count -eq 0','evidence.repository','evidence.base.commit','evidence.base.tree','evidence.head.commit','evidence.head.tree','evidence.plan_sha256',"evidence.platform -cne 'linux'",'expectedIds -join',"evidence.result -cne 'pass'",'Test-Json','cache_inventory_sha256','inventoryPath','AffectedValidationMissingEvidence','FileMode]::CreateNew')) {
        if(-not$source.Contains($required)){throw "Linux direct workflow union evidence guard is absent: $required"}
    }
}

function Assert-TopologyWindowsProfile([string]$Body,[string[]]$StepNames) {
    if($Body-cnotmatch'(?m)^    runs-on: windows-2025\r?$'){throw 'Windows profile requires the explicit Windows Server2025 runner generation.'}
    $install='run: ./scripts/Use-PinnedWindowsPowerShell.ps1 -Install'
    if(([regex]::Matches($Body,[regex]::Escape($install))).Count-ne1){throw 'Windows profile requires exactly one reviewed PowerShell installation.'}
    foreach($stepName in $StepNames) {
        $source=Get-TopologyStepSource $Body $stepName
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Windows profile producer script does not parse.'}
        $statements=@($ast.EndBlock.Statements)
        $assertions=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'./scripts/Use-PinnedWindowsPowerShell.ps1'},$true))
        if($assertions.Count-ne1){throw 'Windows profile must assert the actual pinned producer executable exactly once.'}
        Assert-TopologyClosedTokens './scripts/Use-PinnedWindowsPowerShell.ps1 -AssertCurrent' $assertions[0].Extent.Text
        $assertIndex=-1
        for($i=0;$i-lt$statements.Count;$i++){if($statements[$i].Extent.StartOffset-eq$assertions[0].Extent.StartOffset-and$statements[$i].Extent.EndOffset-eq$assertions[0].Extent.EndOffset){$assertIndex=$i}}
        if($assertIndex-lt0-or$assertIndex+1-ge$statements.Count){throw 'Windows profile assertion must run unconditionally in the actual producer process.'}
        $expected=@'
if ([Environment]::OSVersion.VersionString -cne 'Microsoft Windows NT 10.0.26100.0') { throw 'Affected Windows producer OS differs from the reviewed Windows Server2025 profile.' }
'@
        Assert-TopologyClosedTokens $expected $statements[$assertIndex+1].Extent.Text
        $validationCalls=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$null-ne$node.GetCommandName()-and$node.GetCommandName()-match'(?i)(?:^|[/\\])(?:Resolve|Invoke|Stage|Merge)-AffectedValidation(?:SegmentEvidence|Segments)?\.ps1$'},$true))
        if($validationCalls.Count-eq0){throw 'Windows profile test requires an actual validation producer or aggregate.'}
        foreach($call in $validationCalls){if($call.Extent.StartOffset-le$statements[$assertIndex+1].Extent.EndOffset){throw 'Windows profile identity must be checked before costly validation work.'}}
    }
    if($Body.IndexOf($install,[StringComparison]::Ordinal)-ge$Body.IndexOf($StepNames[0],[StringComparison]::Ordinal)){throw 'Windows profile must install the reviewed shell before its producer steps.'}
}

function Assert-ValidateWorkflowContract([string]$Workflow) {
    Assert-AdvisoryWorkflowJobTimeout $Workflow
    $parts=[regex]::Split($Workflow,'(?m)^jobs:\r?$');if($parts.Count-ne2){throw 'Validate workflow must contain exactly one jobs mapping.'};$jobText=$parts[1]
    [string[]]$jobs=@([regex]::Matches($jobText,'(?m)^  ([a-z0-9-]+):\r?$')|ForEach-Object{$_.Groups[1].Value})
    $expected=@('infrastructure','select','quick-linux','affected-windows-segments','standard-windows','quick-windows','post-merge-attestation','main-windows-segments','main-linux-delta','main-windows-delta','deep')
    if(($jobs-join',')-cne($expected-join',')){throw "Validate workflow job set/order is not exact: $($jobs-join',')"}
    $needs=@{infrastructure=@();select=@('infrastructure');'quick-linux'=@('infrastructure','select');'affected-windows-segments'=@('infrastructure','select');'standard-windows'=@('infrastructure','select','affected-windows-segments');'quick-windows'=@('infrastructure','select','standard-windows');'post-merge-attestation'=@('select');'main-windows-segments'=@('select','post-merge-attestation');'main-linux-delta'=@('select','post-merge-attestation');'main-windows-delta'=@('select','post-merge-attestation','main-windows-segments');deep=@('infrastructure','select','quick-linux','standard-windows')}
    $jobBodies=@{}
    for($index=0;$index-lt$jobs.Count;$index++){$name=$jobs[$index];$start=$jobText.IndexOf("  ${name}:",[StringComparison]::Ordinal);$end=if($index+1-lt$jobs.Count){$jobText.IndexOf("  $($jobs[$index+1]):",$start+1,[StringComparison]::Ordinal)}else{$jobText.Length};$body=$jobText.Substring($start,$end-$start);$jobBodies[$name]=$body;$observed=@();$match=[regex]::Match($body,'(?m)^    needs: (.+)\r?$');if($match.Success){$raw=$match.Groups[1].Value.Trim();$observed=if($raw.StartsWith('[')){@($raw.Trim('[',']')-split ',\s*')}else{@($raw)}};if(($observed-join',')-cne(@($needs[$name])-join',')){throw "Validate workflow needs for '$name' are not exact."};foreach($dependency in $observed){if([Array]::IndexOf($jobs,$dependency)-ge$index){throw "Validate workflow edge is not strictly downward: $name -> $dependency"}};if($body-cnotmatch'(?m)^    timeout-minutes: (?:360|\$\{\{ matrix\.timeout_minutes \}\})\r?$'){throw "Validate workflow job '$name' has no explicit bounded outer timeout."}}
    Assert-TopologyLinuxDirectJob ([string]$jobBodies['quick-linux']) 'Execute exact selected Linux union on this runner'
    Assert-TopologyLinuxDirectJob ([string]$jobBodies['main-linux-delta']) 'Execute exact current Linux delta on this runner'
    $linuxGate=Get-TopologyStepSource ([string]$jobBodies['quick-linux']) 'Bind required Linux selection results'
    $expectedLinuxGate=@'
if ($env:INFRA_RESULT -cne 'success' -or $env:SELECT_RESULT -cne 'success') { throw 'Required Linux selection prerequisites did not succeed.' }
if ($env:LINUX_SELECTED -cnotin @('true','false')) { throw 'Required Linux selection output must be exactly true or false.' }
'@
    Assert-TopologyClosedTokens $expectedLinuxGate $linuxGate
    $mainLinux=[string]$jobBodies['main-linux-delta']
    if(-not$mainLinux.Contains("needs.post-merge-attestation.outputs.execution_mode == 'current-delta'")){throw 'Linux current-delta fallback can run after authenticated reuse.'}
    $mainLinuxGate=Get-TopologyStepSource $mainLinux 'Bind required current Linux delta prerequisites'
    $expectedMainLinuxGate=@'
if ($env:SELECT_RESULT -cne 'success' -or $env:ATTESTATION_RESULT -cne 'success') { throw 'Required current-delta selection prerequisites did not succeed.' }
if ($env:PLATFORM_SELECTED -cne 'true') { throw 'Required current-delta platform selection is not true.' }
'@
    Assert-TopologyClosedTokens $expectedMainLinuxGate $mainLinuxGate
    Assert-TopologyWindowsProfile ([string]$jobBodies['affected-windows-segments']) @('Run affected Windows segment')
    Assert-TopologyWindowsProfile ([string]$jobBodies['standard-windows']) @('Execute exact selected Windows union on this runner','Verify and merge exact Windows segment union')
    Assert-TopologyWindowsProfile ([string]$jobBodies['main-windows-segments']) @('Run current Windows delta segment')
    Assert-TopologyWindowsProfile ([string]$jobBodies['main-windows-delta']) @('Verify current Windows delta segment union')
    $cancellationAwareJobs=@('quick-linux','affected-windows-segments','standard-windows','quick-windows','deep')
    foreach($name in $cancellationAwareJobs){Assert-CancellationAwareCondition -Body ([string]$jobBodies[$name]) -Indent 4 -Label "job '$name'"}
    $failureEvidenceSteps=@(
        'Preserve bounded setup diagnostic',
        'Preserve bounded plan diagnostic',
        'Preserve single-runner Linux aggregate',
        'Preserve single-runner Linux diagnostic',
        'Preserve single-runner Linux check streams and receipts',
        'Save resumable single-runner Linux check cache',
        'Preserve single-runner Linux selector phase evidence',
        'Preserve content-addressed Windows segment evidence',
        'Preserve bounded Windows pre-evidence failure diagnostic',
        'Preserve exact Windows check streams and receipts',
        'Save resumable Windows check cache',
        'Preserve single-runner Windows aggregate',
        'Preserve single-runner Windows diagnostic',
        'Preserve single-runner Windows check streams and receipts',
        'Save resumable single-runner Windows check cache',
        'Preserve bounded current Windows fallback diagnostic',
        'Preserve current Windows delta segment',
        'Preserve current Linux aggregate',
        'Preserve current Linux diagnostic',
        'Preserve current Linux check streams and receipts',
        'Preserve current Linux selector phase evidence'
    )
    foreach($name in $failureEvidenceSteps){$escaped=[regex]::Escape($name);$matches=[regex]::Matches($Workflow,"(?ms)^      - name: $escaped\r?\n(?<body>.*?)(?=^      - |\z)");if($matches.Count-ne1){throw "Validate workflow must contain exactly one '$name' step."};Assert-CancellationAwareCondition -Body $matches[0].Groups['body'].Value -Indent 8 -Label "step '$name'"}
    if($Workflow-cmatch'always\(\)'){throw 'Validate workflow must not retain always()-gated jobs or steps across cancellation.'}
    if(([regex]::Matches($Workflow,'(?m)^(?:    |        )if:\s+\$\{\{\s*!cancelled\(\)\s+&&')).Count-ne27){throw 'Validate workflow cancellation-aware job/step guard set is not exact.'}
    if($Workflow-cmatch'uses:\s*[^\r\n]*validate\.yml'){throw 'Validate workflow recursively invokes itself as a reusable workflow.'}
    foreach($fragment in @("format('validate-pr-{0}', github.event.pull_request.number)","format('validate-main-{0}', github.ref)","github.event_name == 'schedule' && 'validate-deep-schedule'","format('validate-deep-manual-{0}', github.run_id)","cancel-in-progress: `${{ github.event_name == 'pull_request' }}",'phase=''setup''','phase=''plan''','phase=''main-fallback''','FileMode]::CreateNew','bytes.Length-gt65536')){if(-not$Workflow.Contains($fragment)){throw "Validate workflow is missing required bounded/concurrency fragment '$fragment'."}}
    if(([regex]::Matches($Workflow,"'AffectedValidationMissingEvidence'")).Count-ne3){throw 'Validate workflow must synthesize exactly three typed direct/main missing-evidence failures.'}
}
function Invoke-TopologyDirectFailureSelfTest([string]$Workflow,[string]$Fixture) {
    # Execute the real post-executor statements. No validator, Git, provider or
    # runner-profile command is replaced or executed by this fixture.
    $jobs=@{}
    foreach($match in [regex]::Matches($Workflow,'(?ms)^  (?<name>[a-z0-9-]+):\r?\n(?<body>.*?)(?=^  [a-z0-9-]+:|\z)')){$jobs[$match.Groups['name'].Value]=$match.Groups['body'].Value}
    $cases=@('failed-blocked','pass','pass-missing','pass-duplicate','pass-reordered','missing','malformed','wrong-source','unknown','duplicate','reordered','inventory-source','inventory-missing','inventory-blocked-mismatch','inventory-hash','no-inventory','secondary-write')
    $count=0
    foreach($producer in @(
        @{job='quick-linux';step='Execute exact selected Linux union on this runner';platform='linux'},
        @{job='standard-windows';step='Execute exact selected Windows union on this runner';platform='windows'},
        @{job='main-linux-delta';step='Execute exact current Linux delta on this runner';platform='linux'}
    )) {
        $source=Get-TopologyStepSource $jobs[$producer.job] $producer.step
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Direct reporting fixture source does not parse.'}
        $calls=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-eq'./scripts/Invoke-AffectedValidation.ps1'},$true))
        if($calls.Count-ne1){throw 'Direct reporting fixture requires the unique actual executor invocation.'}
        $executorTry=$calls[0].Parent
        while($null-ne$executorTry-and$executorTry-isnot[Management.Automation.Language.TryStatementAst]){$executorTry=$executorTry.Parent}
        $diff=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-eq'git'-and$node.Extent.StartOffset-gt$executorTry.Extent.EndOffset-and$node.Extent.Text.StartsWith('git diff --check',[StringComparison]::Ordinal)},$true))
        if($null-eq$executorTry-or$diff.Count-ne1){throw 'Direct reporting fixture cannot isolate the actual post-executor boundary.'}
        $tail=$source.Substring($executorTry.Extent.EndOffset,$diff[0].Extent.StartOffset-$executorTry.Extent.EndOffset)
        foreach($case in $cases) {
            $caseRoot=Join-Path $Fixture ($producer.job+'-'+$case);[void][IO.Directory]::CreateDirectory($caseRoot)
            [void][IO.Directory]::CreateDirectory((Join-Path $caseRoot 'schemas'))
            foreach($schema in @('affected-validation-evidence-v1.schema.json','affected-validation-check-inventory-v1.schema.json')){[IO.File]::Copy((Join-Path $PSScriptRoot ('../schemas/'+$schema)),(Join-Path $caseRoot ('schemas/'+$schema)))}
            $currentRoot=Join-Path $caseRoot 'cache';[void][IO.Directory]::CreateDirectory($currentRoot)
            $evidencePath=Join-Path $caseRoot 'aggregate.json'
            $plan=[pscustomobject]@{repository='MesmerPrism/rusty-morphospace-work-environment';base=[pscustomobject]@{commit=('a'*40);tree=('b'*40)};head=[pscustomobject]@{commit=('c'*40);tree=('d'*40)};plan_sha256=('e'*64)}
            # Independent topological oracle: second depends on the failed first;
            # the third is independent. Blocked is an inventory disposition only.
            $selected=@('producer-fail','dependent-blocked','independent-pass'|ForEach-Object{[pscustomobject]@{check_id=$_}})
            $passing=$case.StartsWith('pass',[StringComparison]::Ordinal)
            $rows=@()
            foreach($id in @('producer-fail','dependent-blocked','independent-pass')) {
                if(-not$passing-and$id-ceq'dependent-blocked'){continue}
                $fails=-not$passing-and$id-ceq'producer-fail'
                $rows+=[pscustomobject][ordered]@{check_id=$id;command_path='scripts/Test-Example.ps1';command_blob_sha1=('f'*40);mode='executed';result=$(if($fails){'code-fail'}else{'pass'});started=$true;failure_kind=$(if($fails){'exit-code'}else{$null});exit_code=$(if($fails){17}else{0});timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=('0'*64);stderr_sha256=('0'*64);stdout_bytes=0;stderr_bytes=0}
            }
            $document=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_evidence.v1';repository=$plan.repository;base=$plan.base;head=$plan.head;plan_sha256=$plan.plan_sha256;platform=$producer.platform;runner=[pscustomobject]@{os_description='Fixture OS';powershell_version='7.6.0'};check_results=$rows;result=$(if($passing){'pass'}else{'code-fail'});claims=[pscustomobject]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
            $entries=@()
            foreach($id in @('producer-fail','dependent-blocked','independent-pass')) {
                $blocked=-not$passing-and$id-ceq'dependent-blocked'
                $entries+=[pscustomobject][ordered]@{check_id=$id;binding_sha256=('1'*64);mode=$(if($blocked){'blocked'}else{'executed'});result=$(if($blocked){'blocked'}elseif(-not$passing-and$id-ceq'producer-fail'){'code-fail'}else{'pass'});receipt=[pscustomobject]@{path=($id+'/receipt.json');bytes=0;sha256=('0'*64)};stdout=[pscustomobject]@{path=($id+'/stdout.bin');bytes=0;sha256=('0'*64)};stderr=[pscustomobject]@{path=($id+'/stderr.bin');bytes=0;sha256=('0'*64)};artifacts=@()}
            }
            $inventory=[pscustomobject][ordered]@{schema='rusty.morphospace.workflow.affected_validation_check_inventory.v1';producer=[pscustomobject]@{context='github-actions';execution_id=('2'*32);repository=$plan.repository;event_name='pull_request';pull_request_number=1;run_id='1';run_attempt=1;workflow_path='.github/workflows/validate.yml';job=$producer.job};source=[pscustomobject]@{base=$plan.base;head=$plan.head};plan_sha256=$plan.plan_sha256;platform=$producer.platform;entries=$entries;claims=[pscustomobject]@{cache_transport_only=$true;candidate_admission=$false;acceptance_authority=$false;publication_authority=$false}}
            switch($case) {
                'pass-missing' {$document.check_results=@($rows[0],$rows[2])}
                'pass-duplicate' {$document.check_results=@($rows[0],$rows[0],$rows[2])}
                'pass-reordered' {$document.check_results=@($rows[2],$rows[1],$rows[0])}
                'wrong-source' {$document.head=[pscustomobject]@{commit=('9'*40);tree=('d'*40)}}
                'unknown' {$document.check_results[1].check_id='unknown-check'}
                'duplicate' {$document.check_results=@($rows[0],$rows[0])}
                'reordered' {$document.check_results=@($rows[1],$rows[0])}
                'inventory-source' {$inventory.source.head=[pscustomobject]@{commit=('9'*40);tree=('d'*40)}}
                'inventory-missing' {$inventory.entries=@($entries[0],$entries[2])}
                'inventory-blocked-mismatch' {$inventory.entries[1].mode='executed';$inventory.entries[1].result='pass'}
            }
            if($case-cne'missing'){[IO.File]::WriteAllText($evidencePath,$(if($case-ceq'malformed'){'{invalid'}else{$document|ConvertTo-Json -Depth 15}),[Text.UTF8Encoding]::new($false))}
            $inventoryPath=Join-Path $currentRoot 'inventory.json';[IO.File]::WriteAllText($inventoryPath,($inventory|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
            $inventorySha256=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if($case-ceq'inventory-hash'){$inventorySha256='3'*64}
            if($case-ceq'no-inventory'){$inventorySha256=$null}
            $originalFailure=if($passing){$null}else{[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('fixture original executor failure'),'FixtureOriginalExecutorFailure',[Management.Automation.ErrorCategory]::InvalidResult,'producer-fail')}
            $failure=$originalFailure;$caught=$null
            $savedTemp=$env:RUNNER_TEMP;$savedOutput=$env:GITHUB_OUTPUT
            $env:RUNNER_TEMP=$caseRoot;$env:GITHUB_OUTPUT=Join-Path $caseRoot 'outputs.txt'
            if($case-ceq'secondary-write'){$env:GITHUB_OUTPUT=Join-Path $caseRoot 'absent-parent/outputs.txt'}
            Push-Location $caseRoot
            try {
                try { $tailBlock=[scriptblock]::Create($tail);. $tailBlock | Out-Null } catch {$caught=$_}
                $output=if([IO.File]::Exists($env:GITHUB_OUTPUT)){[IO.File]::ReadAllText($env:GITHUB_OUTPUT)}else{''}
                $ready=$output.Contains('evidence_ready=true');$cacheReady=$output.Contains('cache_ready=true')
                if($passing) {
                    if($case-ceq'pass'){if($null-ne$caught-or-not$ready-or-not$cacheReady){throw "Direct reporting $($producer.job) rejected exact full PASS."}}
                    elseif($null-eq$caught-or$ready-or$cacheReady){throw "Direct reporting $($producer.job) accepted damaged PASS coverage: $case"}
                } else {
                    if($null-eq$caught-or-not[object]::ReferenceEquals($caught.Exception,$originalFailure.Exception)){throw "Direct reporting $($producer.job) masked the original executor ErrorRecord: $case"}
                    $wantReady=$case-cin@('failed-blocked','inventory-source','inventory-missing','inventory-blocked-mismatch','inventory-hash','no-inventory')
                    if($ready-ne$wantReady){throw "Direct reporting $($producer.job) misreported aggregate readiness: $case"}
                    if($cacheReady-ne($case-ceq'failed-blocked')){throw "Direct reporting $($producer.job) misreported cache readiness: $case"}
                    if($case-cin@('malformed','wrong-source','unknown','duplicate','reordered','inventory-source','inventory-missing','inventory-blocked-mismatch','inventory-hash','secondary-write')){
                        if(-not$originalFailure.Exception.Data.Contains('AffectedEvidenceReportingFailure')){throw "Direct reporting $($producer.job) lost secondary evidence failure: $case"}
                    }
                    if($case-ceq'missing'-and-not$output.Contains('pre_evidence_failure=true')){throw "Direct reporting $($producer.job) lost missing-evidence diagnostic."}
                }
                $count++
            } finally {$env:RUNNER_TEMP=$savedTemp;$env:GITHUB_OUTPUT=$savedOutput;Pop-Location}
        }
    }
    Write-Host "Direct producer reporting passed $count actual-workflow-tail causal cases."
}
if ($SelfTest) {
    function Invoke-TopologySelfGit([string]$Root, [string[]]$Arguments) { $value = & git -C $Root @Arguments 2>&1; if ($LASTEXITCODE -ne 0) { throw "Topology self-test git failure: $($value -join "`n")" }; return ($value -join "`n").Trim() }
    function Write-TopologySelfUtf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('morphospace-affected-topology-' + [Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($fixture)
    try {
        $currentWorkflow=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\.github\workflows\validate.yml'),[Text.UTF8Encoding]::new($false,$true));Assert-ValidateWorkflowContract $currentWorkflow
        Invoke-TopologyDirectFailureSelfTest $currentWorkflow $fixture
        # Only this owner self-test executes the actual policy after its closed
        # source contract has passed. Ordinary repository attestation never does.
        $definition=[regex]::Match($currentWorkflow,'(?ms)^          function Get-AffectedJobTimeoutMinutes\([^\r\n]*\) \{\r?\n.*?^          \}')
    $policy = [scriptblock]::Create($definition.Value + "`n" + 'Get-AffectedJobTimeoutMinutes -EstimatedBudgetSeconds $args[0]')
    foreach ($estimate in @(0L, 18000L, 20700L, 86400L)) {
        $observations = @(& $policy $estimate 3>&1)
        $warnings = @($observations | Where-Object { $_ -is [Management.Automation.WarningRecord] })
        $values = @($observations | Where-Object { $_ -isnot [Management.Automation.WarningRecord] })
        if ($values.Count -ne 1 -or $values[0] -ne 360 -or $warnings.Count -ne [int]($estimate -ge 20700)) {
            throw 'Validate workflow estimate changed job admission or omitted its advisory warning.'
        }
    }
    $failedWarning = [scriptblock]::Create("function Write-Warning { throw 'MODELED warning publication failure' }`n" + $definition.Value + "`nGet-AffectedJobTimeoutMinutes -EstimatedBudgetSeconds 86400")
    if ((& $failedWarning) -ne 360) { throw 'Validate workflow warning publication blocked the job.' }

        $damages=[ordered]@{edge=$currentWorkflow.Replace('needs: infrastructure','needs: deep');concurrency=$currentWorkflow.Replace("github.event_name == 'schedule' && 'validate-deep-schedule' || format('validate-deep-manual-{0}', github.run_id)","'validate-deep-schedule-manual'");timeout=$currentWorkflow.Replace('timeout-minutes: 360','timeout-minutes-removed: 360');shortTimeout=$currentWorkflow.Replace('timeout-minutes: 360','timeout-minutes: 10');shortPolicy=$currentWorkflow.Replace('return 360','return 359');estimateRefusal=$currentWorkflow.Replace('return 360',"throw 'MODELED estimated job refusal'");matrixBinding=$currentWorkflow.Replace('timeout_minutes=(Get-AffectedJobTimeoutMinutes -EstimatedBudgetSeconds ([long]$_.estimated_budget_seconds))','timeout_minutes=360');recursion=$currentWorkflow.Replace('uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1','uses: ./.github/workflows/validate.yml');missingEvidence=$currentWorkflow.Replace("'AffectedValidationMissingEvidence'","'AffectedValidationMissingEvidenceRemoved'");missingPinInstall=[regex]::Replace($currentWorkflow,'run: ./scripts/Use-PinnedWindowsPowerShell.ps1 -Install','run: ./scripts/Use-PinnedWindowsPowerShell.ps1 -Removed',1);missingPinAssertion=[regex]::Replace($currentWorkflow,'./scripts/Use-PinnedWindowsPowerShell.ps1 -AssertCurrent','./scripts/Use-PinnedWindowsPowerShell.ps1 -Removed',1);cancelRetainingJob=[regex]::Replace($currentWorkflow,'(?m)^    if: \$\{\{ !cancelled\(\) &&','    if: ${{ always() &&',1);cancelRetainingStep=[regex]::Replace($currentWorkflow,'(?m)^        if: \$\{\{ !cancelled\(\) &&','        if: ${{ always() &&',1);failureSkippingJob=[regex]::Replace($currentWorkflow,'(?m)^    if: \$\{\{ !cancelled\(\) &&','    if: ${{ success() &&',1);failureSkippingStep=[regex]::Replace($currentWorkflow,'(?m)^        if: \$\{\{ !cancelled\(\) &&','        if: ${{ success() &&',1)}
        $matrixCall='timeout_minutes=(Get-AffectedJobTimeoutMinutes -EstimatedBudgetSeconds ([long]$_.estimated_budget_seconds))'
        $damages['matrixCommentDecoy']=$currentWorkflow.Replace($matrixCall,'timeout_minutes=359')+"`n# $matrixCall`n"
        $damages['helperCommentDecoy']=$currentWorkflow.Replace('return 360','return 359')+"`n# return 360`n"
        $foreachPlatform='          foreach ($platform in @(''linux'',''windows'')) {'
        $matrixAssignment='            $matrix = [pscustomobject][ordered]@{include=@($include)}'
        $damages['helperCaseCollision']=$currentWorkflow.Replace($foreachPlatform,'          function get-affectedjobtimeoutminutes([long]$EstimatedBudgetSeconds) { return 359 }'+"`n"+$foreachPlatform)
        $damages['helperScopedCollision']=$currentWorkflow.Replace($foreachPlatform,'          function script:get-affectedjobtimeoutminutes([long]$EstimatedBudgetSeconds) { return 359 }'+"`n"+$foreachPlatform)
        $damages['includeCaseCollision']=$currentWorkflow.Replace($matrixAssignment,'            $Include = @([pscustomobject]@{segment_id=''linux-001'';timeout_minutes=359})'+"`n"+$matrixAssignment)
        $damages['includeScopedCollision']=$currentWorkflow.Replace($matrixAssignment,'            $script:Include = @([pscustomobject]@{segment_id=''linux-001'';timeout_minutes=359})'+"`n"+$matrixAssignment)
        $linuxInvocation='& ./scripts/Invoke-AffectedValidation.ps1 -RepositoryRoot . -BaseCommit $base -HeadCommit $head -PlanPath "$env:RUNNER_TEMP/affected-plan.json" -Platform linux -OutPath $evidencePath -CheckEvidenceDirectory $currentRoot -PriorEvidenceDirectory $priorRoot'
        $damages['linuxSplitParent']=$currentWorkflow.Replace('-Platform linux -OutPath','-Platform linux -SegmentId linux-001 -OutPath')
        $damages['linuxForeignExecutor']=$currentWorkflow.Replace('./scripts/Invoke-AffectedValidation.ps1','./foreign/Invoke-AffectedValidation.ps1')
        $damages['linuxCommandCommentDecoy']=$currentWorkflow.Replace($linuxInvocation,('# '+$linuxInvocation+"`n          `$execution = `$null"))
        $damages['linuxDuplicateCommand']=$currentWorkflow.Replace($linuxInvocation,($linuxInvocation+"`n          "+$linuxInvocation))
        $damages['linuxWrongTier']=$currentWorkflow.Replace("{ 'Deep' } else { 'Quick' }","{ 'Quick' } else { 'Deep' }")
        $damages['linuxDuplicateJob']=$currentWorkflow+"`n  quick-linux:`n    needs: [infrastructure, select]`n"
        $damages['linuxAmbiguousSegments']=$currentWorkflow+"`n  affected-linux-segments:`n    runs-on: ubuntu-latest`n"
        $damages['linuxLostFallbackGate']=$currentWorkflow.Replace("needs.post-merge-attestation.outputs.execution_mode == 'current-delta'","needs.post-merge-attestation.outputs.execution_mode != 'current-delta'")
        foreach($extraJob in @('quick-linux','main-linux-delta')) {
            $jobPattern='(?ms)(^  '+[regex]::Escape($extraJob)+':\r?\n)(?<body>.*?)(?=^  [a-z0-9-]+:|\z)'
            $jobMatch=[regex]::Match($currentWorkflow,$jobPattern)
            $insertAt=$jobMatch.Groups['body'].Index+$jobMatch.Groups['body'].Length
            $damages['linuxExtraStep-'+$extraJob]=$currentWorkflow.Insert($insertAt,("      - name: Undeclared second Linux producer`n        shell: pwsh`n        run: |`n          "+$linuxInvocation+"`n"))
            $damages['linuxExtraInline-'+$extraJob]=$currentWorkflow.Insert($insertAt,("      - name: Undeclared inline Linux producer`n        shell: pwsh`n        run: "+$linuxInvocation+"`n"))
        }
        $windowsGuard="if ([Environment]::OSVersion.VersionString -cne 'Microsoft Windows NT 10.0.26100.0') { throw 'Affected Windows producer OS differs from the reviewed Windows Server2025 profile.' }"
        $windowsPin='./scripts/Use-PinnedWindowsPowerShell.ps1 -AssertCurrent'
        $damages['windowsMovingImage']=$currentWorkflow.Replace('runs-on: windows-2025','runs-on: windows-latest')
        $damages['windowsWrongOS']=$currentWorkflow.Replace('Microsoft Windows NT 10.0.26100.0','Microsoft Windows NT 10.0.20348.0')
        $damages['windowsMissingOS']=$currentWorkflow.Replace($windowsGuard,'')
        $damages['windowsCommentedOS']=$currentWorkflow.Replace($windowsGuard,('# '+$windowsGuard))
        $damages['windowsLateOS']=$currentWorkflow.Replace(($windowsPin+"`n          "+$windowsGuard),($windowsPin+"`n          ./scripts/Resolve-AffectedValidation.ps1 -RepositoryRoot .`n          "+$windowsGuard))
        $damages['windowsBypassPin']=$currentWorkflow.Replace($windowsPin,'./scripts/Use-PinnedWindowsPowerShell.ps1 -SelfTest')
        $damages['windowsNestedPin']=$currentWorkflow.Replace($windowsPin,('if ($false) { '+$windowsPin+' }'))
        foreach($profileStep in @('Run affected Windows segment','Execute exact selected Windows union on this runner','Verify and merge exact Windows segment union','Run current Windows delta segment','Verify current Windows delta segment union')) {
            $stepPattern='(?ms)(^      - name: '+[regex]::Escape($profileStep)+'\r?\n.*?^        run: \|\r?\n)(?<source>.*?)(?=^      - |^  [a-z]|\z)'
            $stepMatch=[regex]::Match($currentWorkflow,$stepPattern)
            if(-not$stepMatch.Success-or-not$stepMatch.Groups['source'].Value.Contains($windowsGuard)){throw "Windows profile damage fixture lacks its real guard: $profileStep"}
            $damageSource=$stepMatch.Groups['source'].Value.Replace($windowsGuard,'')
            $damages['windowsUncovered-'+$profileStep]=$currentWorkflow.Substring(0,$stepMatch.Groups['source'].Index)+$damageSource+$currentWorkflow.Substring($stepMatch.Groups['source'].Index+$stepMatch.Groups['source'].Length)
        }
        foreach($damageName in $damages.Keys){$rejected=$false;try{Assert-ValidateWorkflowContract ([string]$damages[$damageName])}catch{$rejected=$true};if(-not$rejected){throw "Validate workflow contract self-test accepted $damageName damage."}}
        [void](Invoke-TopologySelfGit $fixture @('init', '--initial-branch=main')); [void](Invoke-TopologySelfGit $fixture @('config', 'user.name', 'Topology Test')); [void](Invoke-TopologySelfGit $fixture @('config', 'user.email', 'topology@example.invalid'))
        Write-TopologySelfUtf8 (Join-Path $fixture 'base.txt') "base`n"; [void](Invoke-TopologySelfGit $fixture @('add','.')); [void](Invoke-TopologySelfGit $fixture @('commit','-m','base')); $base = Invoke-TopologySelfGit $fixture @('rev-parse','HEAD')
        [void](Invoke-TopologySelfGit $fixture @('checkout','-b','candidate')); Write-TopologySelfUtf8 (Join-Path $fixture 'candidate.txt') "candidate`n"; [void](Invoke-TopologySelfGit $fixture @('add','.')); [void](Invoke-TopologySelfGit $fixture @('commit','-m','candidate')); $candidate = Invoke-TopologySelfGit $fixture @('rev-parse','HEAD')
        [void](Invoke-TopologySelfGit $fixture @('checkout','main')); Write-TopologySelfUtf8 (Join-Path $fixture 'main.txt') "main`n"; [void](Invoke-TopologySelfGit $fixture @('add','.')); [void](Invoke-TopologySelfGit $fixture @('commit','-m','main')); $before = Invoke-TopologySelfGit $fixture @('rev-parse','HEAD')
        [void](Invoke-TopologySelfGit $fixture @('merge','--no-ff','candidate','-m','merge candidate')); $merge = Invoke-TopologySelfGit $fixture @('rev-parse','HEAD')
        $attestation = & $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $before -HeadCommit $merge
        if ($attestation.mode -cne 'main-delta' -or $attestation.candidate.commit -cne $candidate -or [bool]$attestation.claims.reuse_eligible) { throw 'Topology self-test accepted a changed merge tree for reuse.' }
        $wrongBeforeRejected = $false; try { [void](& $PSCommandPath -RepositoryRoot $fixture -BeforeCommit $base -HeadCommit $merge) } catch { $wrongBeforeRejected = $true }; if (-not $wrongBeforeRejected) { throw 'Topology self-test accepted a mismatched first parent.' }
        Write-Host 'Affected-validation topology self-test passed.'
    } finally { if ([IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
    return
}
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$workflowPath=Join-Path $root '.github\workflows\validate.yml';if([IO.File]::Exists($workflowPath)){Assert-ValidateWorkflowContract ([IO.File]::ReadAllText($workflowPath,[Text.UTF8Encoding]::new($false,$true)))}
Import-Module (Join-Path $PSScriptRoot 'lib/MorphospaceProtocolCommon.psm1') -Force
function Invoke-TopologyGit([string[]]$Arguments) {
    $value = & git -C $root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Topology attestation git failure: $($Arguments -join ' ')`n$($value -join "`n")" }
    return ($value -join "`n").Trim()
}
function Get-TopologyIdentity([string]$Revision) {
    $commit = Invoke-TopologyGit @('rev-parse', "$Revision^{commit}")
    $tree = Invoke-TopologyGit @('rev-parse', "$Revision^{tree}")
    return [pscustomobject][ordered]@{ commit=$commit; tree=$tree }
}

if ($BeforeCommit -notmatch '^[0-9a-f]{40}$' -or $HeadCommit -notmatch '^[0-9a-f]{40}$') { throw 'Topology attestation requires full lowercase commit identities.' }
$before = Get-TopologyIdentity $BeforeCommit
$head = Get-TopologyIdentity $HeadCommit
if ((Get-TopologyIdentity 'HEAD').commit -cne $head.commit) { throw 'Topology attestation requires the checked out HEAD to equal the supplied head.' }
$parentText = Invoke-TopologyGit @('show', '-s', '--format=%P', $head.commit)
$parents = @($parentText -split '\s+' | Where-Object { $_ })
$candidate = $null
$mode = 'main-delta'
if ($parents.Count -eq 2) {
    $firstParent = Get-TopologyIdentity $parents[0]
    $candidate = Get-TopologyIdentity $parents[1]
    if ($before.commit -cne $firstParent.commit) { throw 'Merge topology does not bind the event before commit to the first parent.' }
    if ($head.tree -ceq $candidate.tree) { $mode = 'exact-tree-premerge-reuse' }
} elseif ($parents.Count -eq 1) {
    $ancestor = & git -C $root merge-base --is-ancestor $before.commit $head.commit
    if ($LASTEXITCODE -ne 0) { throw 'Main delta topology requires before to be an ancestor of head.' }
} else { throw 'Topology attestation rejects root commits.' }
$attestation = [pscustomobject][ordered]@{
    schema='rusty.morphospace.workflow.affected_validation_topology_attestation.v1'
    before=$before
    head=$head
    mode=$mode
    candidate=$candidate
    claims=[pscustomobject][ordered]@{ reuse_eligible=($mode -ceq 'exact-tree-premerge-reuse'); historical_aggregate_reused=$false; acceptance_authority=$false; publication_authority=$false }
}
$json = ConvertTo-MorphospaceCanonicalJson -Value $attestation
$schema = Join-Path $PSScriptRoot '..\schemas\affected-validation-topology-attestation-v1.schema.json'
if (-not (Test-Json -Json $json -SchemaFile $schema -ErrorAction Stop)) { throw 'Topology attestation fails its closed schema.' }
$attestation
