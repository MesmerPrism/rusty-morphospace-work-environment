param(
    [string]$Path = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$IdPattern = "^[a-z0-9][a-z0-9-]{1,63}$"
$RevisionPattern = "^(?:[0-9a-f]{40}|[0-9a-f]{64})$"

function Add-ReceiptFailure {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Message
    )

    $Failures.Add($Message) | Out-Null
}

function Test-ReceiptText {
    param([object]$Value)

    return -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Test-ReceiptProperty {
    param(
        [object]$Value,
        [string]$Property
    )

    return $null -ne $Value -and $Value.PSObject.Properties.Name -contains $Property
}

function Test-ExactSequence {
    param(
        [object[]]$Actual,
        [object[]]$Expected
    )

    $actualItems = @($Actual | ForEach-Object { [string]$_ })
    $expectedItems = @($Expected | ForEach-Object { [string]$_ })
    if ($actualItems.Count -ne $expectedItems.Count) {
        return $false
    }
    for ($index = 0; $index -lt $actualItems.Count; $index++) {
        if ($actualItems[$index] -cne $expectedItems[$index]) {
            return $false
        }
    }
    return $true
}

function Test-ReceiptIds {
    param(
        [object[]]$Values,
        [string]$Context,
        [System.Collections.Generic.List[string]]$Failures,
        [bool]$RequireNonEmpty = $true
    )

    $items = @($Values | ForEach-Object { [string]$_ })
    if ($RequireNonEmpty -and $items.Count -eq 0) {
        Add-ReceiptFailure -Failures $Failures -Message "$Context must contain at least one ID."
        return
    }
    $seen = @{}
    foreach ($item in $items) {
        if ($item -cnotmatch $IdPattern) {
            Add-ReceiptFailure -Failures $Failures -Message "$Context contains invalid ID '$item'."
        }
        if ($seen.ContainsKey($item)) {
            Add-ReceiptFailure -Failures $Failures -Message "$Context repeats ID '$item'."
        }
        $seen[$item] = $true
    }
}

function Test-ExecutedPushReceiptDocument {
    param([object]$Document)

    $failures = New-Object System.Collections.Generic.List[string]
    $required = @(
        "schema", "receipt_id", "bundle_id", "project_id", "unit_ids",
        "prepared_plan_id", "started_at", "finished_at", "status", "execution",
        "dependency_order", "execution_order", "repositories", "validation",
        "rollback", "source_first", "planning_last", "force_push_used",
        "remote_readback_complete", "failure"
    )
    foreach ($property in $required) {
        if (-not (Test-ReceiptProperty -Value $Document -Property $property)) {
            Add-ReceiptFailure -Failures $failures -Message "Receipt is missing required property '$property'."
        }
    }

    if ([string]$Document.schema -cne "rusty.morphospace.workflow.executed_push_receipt.v1") {
        Add-ReceiptFailure -Failures $failures -Message "Receipt has the wrong schema ID."
    }
    foreach ($property in @("receipt_id", "bundle_id", "project_id", "prepared_plan_id")) {
        $value = [string]$Document.$property
        if ($value -cnotmatch $IdPattern) {
            Add-ReceiptFailure -Failures $failures -Message "Receipt property '$property' has invalid ID '$value'."
        }
    }
    Test-ReceiptIds -Values @($Document.unit_ids) -Context "unit_ids" -Failures $failures

    $started = [DateTimeOffset]::MinValue
    $finished = [DateTimeOffset]::MinValue
    $startedValid = [DateTimeOffset]::TryParse([string]$Document.started_at, [ref]$started)
    $finishedValid = [DateTimeOffset]::TryParse([string]$Document.finished_at, [ref]$finished)
    if (-not $startedValid) {
        Add-ReceiptFailure -Failures $failures -Message "started_at is not a valid timestamp."
    }
    if (-not $finishedValid) {
        Add-ReceiptFailure -Failures $failures -Message "finished_at is not a valid timestamp."
    }
    if ($startedValid -and $finishedValid -and $finished -lt $started) {
        Add-ReceiptFailure -Failures $failures -Message "finished_at must not precede started_at."
    }

    if ([string]$Document.status -cne "validated-pushed") {
        Add-ReceiptFailure -Failures $failures -Message "Executed receipt status must be 'validated-pushed'."
    }
    if ([string]$Document.execution -cne "externally-performed") {
        Add-ReceiptFailure -Failures $failures -Message "Executed receipt must say execution is externally-performed."
    }
    if ($Document.source_first -ne $true) {
        Add-ReceiptFailure -Failures $failures -Message "Validated receipt must record source_first=true."
    }
    if ($Document.planning_last -ne $true) {
        Add-ReceiptFailure -Failures $failures -Message "Validated receipt must record planning_last=true."
    }
    if ($Document.force_push_used -ne $false) {
        Add-ReceiptFailure -Failures $failures -Message "Validated receipt must record force_push_used=false."
    }
    if ($Document.remote_readback_complete -ne $true) {
        Add-ReceiptFailure -Failures $failures -Message "Validated receipt must record remote_readback_complete=true."
    }
    if ($null -ne $Document.failure) {
        Add-ReceiptFailure -Failures $failures -Message "Validated receipt must leave failure null."
    }

    $dependencyOrder = @($Document.dependency_order | ForEach-Object { [string]$_ })
    $executionOrder = @($Document.execution_order | ForEach-Object { [string]$_ })
    Test-ReceiptIds -Values $dependencyOrder -Context "dependency_order" -Failures $failures
    Test-ReceiptIds -Values $executionOrder -Context "execution_order" -Failures $failures
    if (-not (Test-ExactSequence -Actual $executionOrder -Expected $dependencyOrder)) {
        Add-ReceiptFailure -Failures $failures -Message "execution_order must exactly match dependency_order."
    }

    $validationRows = @($Document.validation)
    if ($validationRows.Count -eq 0) {
        Add-ReceiptFailure -Failures $failures -Message "validation must contain at least one gate."
    }
    $validationMap = @{}
    $validationUse = @{}
    foreach ($gate in $validationRows) {
        $gateId = [string]$gate.gate_id
        if ($gateId -cnotmatch $IdPattern) {
            Add-ReceiptFailure -Failures $failures -Message "Validation gate has invalid ID '$gateId'."
        }
        if ($validationMap.ContainsKey($gateId)) {
            Add-ReceiptFailure -Failures $failures -Message "Validation repeats gate '$gateId'."
        } else {
            $validationMap[$gateId] = $gate
            $validationUse[$gateId] = 0
        }
        if ([string]$gate.status -cne "pass") {
            Add-ReceiptFailure -Failures $failures -Message "Validation gate '$gateId' must pass for a validated receipt."
        }
        if (-not (Test-ReceiptText $gate.evidence)) {
            Add-ReceiptFailure -Failures $failures -Message "Validation gate '$gateId' needs evidence."
        }
    }

    $repositories = @($Document.repositories)
    if ($repositories.Count -eq 0) {
        Add-ReceiptFailure -Failures $failures -Message "repositories must contain at least one ref."
    }
    $repositoryMap = @{}
    foreach ($repository in $repositories) {
        $refId = [string]$repository.ref_id
        if ($refId -cnotmatch $IdPattern) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref has invalid ID '$refId'."
        }
        if ($repositoryMap.ContainsKey($refId)) {
            Add-ReceiptFailure -Failures $failures -Message "Repository refs repeat '$refId'."
        } else {
            $repositoryMap[$refId] = $repository
        }
        if ([string]$repository.repo_id -cnotmatch $IdPattern) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' has an invalid repo_id."
        }
        if (@("source-owner", "planning") -cnotcontains [string]$repository.role) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' has invalid role '$($repository.role)'."
        }
        foreach ($property in @("branch", "remote", "upstream")) {
            if (-not (Test-ReceiptText $repository.$property)) {
                Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' needs '$property'."
            }
        }
        if (@("pushed", "readback-only") -cnotcontains [string]$repository.action) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' has invalid action '$($repository.action)'."
        }
        foreach ($property in @("old_revision", "new_revision", "observed_remote_revision", "rollback_revision")) {
            if ([string]$repository.$property -cnotmatch $RevisionPattern) {
                Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' has invalid full revision in '$property'."
            }
        }
        if ([string]$repository.action -ceq "pushed" -and [string]$repository.old_revision -ceq [string]$repository.new_revision) {
            Add-ReceiptFailure -Failures $failures -Message "Pushed ref '$refId' must change revision; use readback-only for a no-op."
        }
        if ([string]$repository.action -ceq "readback-only" -and [string]$repository.old_revision -cne [string]$repository.new_revision) {
            Add-ReceiptFailure -Failures $failures -Message "Readback-only ref '$refId' must keep old_revision equal to new_revision."
        }
        if ([string]$repository.observed_remote_revision -cne [string]$repository.new_revision) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' remote readback must equal new_revision."
        }
        if ([string]$repository.push_status -cne "pass") {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' push_status must be pass."
        }
        if ($repository.ancestry_verified -ne $true) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' must record ancestry_verified=true."
        }
        if ($repository.remote_match -ne $true) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' must record remote_match=true."
        }
        if ($repository.force_push_used -ne $false) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' must record force_push_used=false."
        }
        if ([string]$repository.rollback_revision -cne [string]$repository.old_revision) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' rollback_revision must equal old_revision."
        }
        $validationRefs = @($repository.validation_refs | ForEach-Object { [string]$_ })
        Test-ReceiptIds -Values $validationRefs -Context "Repository ref '$refId' validation_refs" -Failures $failures
        foreach ($gateId in $validationRefs) {
            if (-not $validationMap.ContainsKey($gateId)) {
                Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' references unknown validation gate '$gateId'."
            } else {
                $validationUse[$gateId] = [int]$validationUse[$gateId] + 1
                if ([string]$validationMap[$gateId].status -cne "pass") {
                    Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' references non-passing validation gate '$gateId'."
                }
            }
        }
    }

    foreach ($refId in $dependencyOrder) {
        if (-not $repositoryMap.ContainsKey($refId)) {
            Add-ReceiptFailure -Failures $failures -Message "dependency_order references unknown repository ref '$refId'."
        }
    }
    foreach ($refId in $repositoryMap.Keys) {
        if ($dependencyOrder -cnotcontains $refId) {
            Add-ReceiptFailure -Failures $failures -Message "Repository ref '$refId' is missing from dependency_order."
        }
    }

    $planningRows = @($repositories | Where-Object { [string]$_.role -ceq "planning" })
    if ($planningRows.Count -ne 1) {
        Add-ReceiptFailure -Failures $failures -Message "Validated receipt must contain exactly one planning ref."
    } elseif ($executionOrder.Count -eq 0 -or $executionOrder[-1] -cne [string]$planningRows[0].ref_id) {
        Add-ReceiptFailure -Failures $failures -Message "Planning ref must be the final execution_order entry."
    }
    for ($index = 0; $index -lt [Math]::Max(0, $executionOrder.Count - 1); $index++) {
        $refId = $executionOrder[$index]
        if ($repositoryMap.ContainsKey($refId) -and [string]$repositoryMap[$refId].role -cne "source-owner") {
            Add-ReceiptFailure -Failures $failures -Message "Only source-owner refs may precede the final planning ref."
        }
    }

    foreach ($gateId in $validationUse.Keys) {
        if ([int]$validationUse[$gateId] -eq 0) {
            Add-ReceiptFailure -Failures $failures -Message "Validation gate '$gateId' is not referenced by any repository ref."
        }
    }

    if ([string]$Document.rollback.strategy -cne "revert-in-reverse-dependency-order") {
        Add-ReceiptFailure -Failures $failures -Message "Rollback strategy must be revert-in-reverse-dependency-order."
    }
    $expectedReverse = @($executionOrder)
    [array]::Reverse($expectedReverse)
    $actualReverse = @($Document.rollback.reverse_dependency_order | ForEach-Object { [string]$_ })
    Test-ReceiptIds -Values $actualReverse -Context "rollback.reverse_dependency_order" -Failures $failures
    if (-not (Test-ExactSequence -Actual $actualReverse -Expected $expectedReverse)) {
        Add-ReceiptFailure -Failures $failures -Message "rollback.reverse_dependency_order must exactly reverse execution_order."
    }

    $rollbackPoints = @($Document.rollback.points)
    $rollbackPointIds = @($rollbackPoints | ForEach-Object { [string]$_.ref_id })
    Test-ReceiptIds -Values $rollbackPointIds -Context "rollback.points" -Failures $failures
    if (-not (Test-ExactSequence -Actual $rollbackPointIds -Expected $expectedReverse)) {
        Add-ReceiptFailure -Failures $failures -Message "rollback.points must follow reverse dependency order."
    }
    foreach ($point in $rollbackPoints) {
        $refId = [string]$point.ref_id
        if (-not $repositoryMap.ContainsKey($refId)) {
            Add-ReceiptFailure -Failures $failures -Message "Rollback point references unknown repository ref '$refId'."
            continue
        }
        if ([string]$point.rollback_revision -cne [string]$repositoryMap[$refId].old_revision) {
            Add-ReceiptFailure -Failures $failures -Message "Rollback point '$refId' must use the repository old_revision."
        }
        if (-not (Test-ReceiptText $point.acceptance)) {
            Add-ReceiptFailure -Failures $failures -Message "Rollback point '$refId' needs acceptance evidence."
        }
    }

    return $failures.ToArray()
}

function Read-ReceiptDocument {
    param([string]$ReceiptPath)

    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
        throw "Executed push receipt is missing: $ReceiptPath"
    }
    try {
        return Get-Content -Raw -LiteralPath $ReceiptPath | ConvertFrom-Json
    } catch {
        throw "Executed push receipt is not valid JSON: $($_.Exception.Message)"
    }
}

function Assert-ReceiptSchema {
    param([string]$ReceiptPath)

    $testJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if (-not $testJson) {
        return
    }
    $schemaPath = Join-Path $RepoRoot "schemas\executed-push-receipt.schema.json"
    try {
        $valid = Get-Content -Raw -LiteralPath $ReceiptPath |
            Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    } catch {
        throw "Executed push receipt failed JSON Schema validation: $($_.Exception.Message)"
    }
    if (-not $valid) {
        throw "Executed push receipt failed JSON Schema validation."
    }
}

function Assert-ReceiptValid {
    param(
        [object]$Document,
        [string]$Context
    )

    $failures = @(Test-ExecutedPushReceiptDocument -Document $Document)
    if ($failures.Count -gt 0) {
        Write-Host "$Context validation failures:"
        foreach ($failure in $failures) {
            Write-Host " - $failure"
        }
        throw "$Context failed with $($failures.Count) error(s)."
    }
}

function Copy-ReceiptDocument {
    param([object]$Document)

    return $Document | ConvertTo-Json -Depth 50 | ConvertFrom-Json
}

if ($Path) {
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    Assert-ReceiptSchema -ReceiptPath $resolvedPath
    $document = Read-ReceiptDocument -ReceiptPath $resolvedPath
    Assert-ReceiptValid -Document $document -Context "Executed push receipt '$resolvedPath'"
    Write-Host "Executed push receipt validation passed: $resolvedPath"
}

if ($SelfTest) {
    $templatePath = Join-Path $RepoRoot "templates\executed-push-receipt.example.json"
    Assert-ReceiptSchema -ReceiptPath $templatePath
    $template = Read-ReceiptDocument -ReceiptPath $templatePath
    Assert-ReceiptValid -Document $template -Context "Executed push receipt example"

    $damageCases = @(
        [pscustomobject]@{
            Name = "planning-last"
            Expected = "Planning ref must be the final"
            Mutate = { param($value) $value.execution_order = @("planning-main", "matter-main", "workflow-main") }
        },
        [pscustomobject]@{
            Name = "exact-readback"
            Expected = "remote readback must equal new_revision"
            Mutate = { param($value) $value.repositories[0].observed_remote_revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
        },
        [pscustomobject]@{
            Name = "ancestry"
            Expected = "ancestry_verified=true"
            Mutate = { param($value) $value.repositories[0].ancestry_verified = $false }
        },
        [pscustomobject]@{
            Name = "force-push"
            Expected = "force_push_used=false"
            Mutate = { param($value) $value.force_push_used = $true }
        },
        [pscustomobject]@{
            Name = "ref-force-push"
            Expected = "must record force_push_used=false"
            Mutate = { param($value) $value.repositories[0].force_push_used = $true }
        },
        [pscustomobject]@{
            Name = "validation"
            Expected = "must pass for a validated receipt"
            Mutate = { param($value) $value.validation[0].status = "fail" }
        },
        [pscustomobject]@{
            Name = "validation-reference"
            Expected = "references unknown validation gate"
            Mutate = { param($value) $value.repositories[0].validation_refs = @("missing-gate") }
        },
        [pscustomobject]@{
            Name = "rollback-order"
            Expected = "must exactly reverse execution_order"
            Mutate = { param($value) $value.rollback.reverse_dependency_order = @("matter-main", "workflow-main", "planning-main") }
        },
        [pscustomobject]@{
            Name = "rollback-revision"
            Expected = "rollback_revision must equal old_revision"
            Mutate = { param($value) $value.repositories[0].rollback_revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
        },
        [pscustomobject]@{
            Name = "rollback-point"
            Expected = "must use the repository old_revision"
            Mutate = { param($value) $value.rollback.points[2].rollback_revision = "cccccccccccccccccccccccccccccccccccccccc" }
        }
    )

    foreach ($case in $damageCases) {
        $damaged = Copy-ReceiptDocument -Document $template
        & $case.Mutate $damaged
        $failures = @(Test-ExecutedPushReceiptDocument -Document $damaged)
        if ($failures.Count -eq 0) {
            throw "Damage case '$($case.Name)' unexpectedly passed."
        }
        if (@($failures | Where-Object { $_ -like "*$($case.Expected)*" }).Count -eq 0) {
            throw "Damage case '$($case.Name)' failed for the wrong reason: $($failures -join ' | ')"
        }
    }

    Write-Host "Executed push receipt self-test passed (valid example plus $($damageCases.Count) damaged cases)."
}

if (-not $Path -and -not $SelfTest) {
    throw "Specify -Path <executed-receipt.json> or -SelfTest."
}
