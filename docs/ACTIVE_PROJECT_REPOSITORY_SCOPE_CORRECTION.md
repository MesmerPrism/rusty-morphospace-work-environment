# Active Project Repository Scope Correction

`CorrectActiveProjectRepositoryScope` is the narrow transactional route for an
already-active unit whose exact writable path is declared by the unit but was
omitted from the corresponding project repository allow-list. It is not a
generic project amendment action.

Use it only while the unit is the exact `workspace.state.json.current_unit`,
has status `active`, and has not begun validation. The correction can add paths
only when each new path is an exact path already present in that unit's
`allowed_repositories` entry for the same repository. It cannot remove a path,
change a repository identity, role, or root, edit the unit, add a prefix broader
than the unit declaration, or touch source repositories.

## Transaction boundary

The input contract is
`rusty.morphospace.workflow.active_project_repository_scope_correction.v1`.
It compare-and-swap binds:

- the canonical project, feature-lock, state, and unit hashes;
- the current project, feature-lock, and plan revisions;
- the byte-exact event-ledger hash and length plus its tail identity;
- the exact repository ID and complete before/after project path sets; and
- the active/current status and unit identity.

The action derives every target. A successful transaction:

- increments the project revision by one;
- changes only the target repository's `allowed_paths` in the project spec;
- increments and regenerates the closed-world feature lock without changing
  its selected features or effect union;
- increments `state.plan_revision`, updates the module-registry lock binding,
  and records the new event as `state.last_event_id`;
- preserves the unit document byte-for-byte;
- installs the exact correction input as its audit receipt; and
- appends exactly one event.

Transition-ledger intent v3 owns the project and feature-lock projections in
the same recoverable transaction as state, unit, receipt, and event. An
interrupted v3 transaction blocks later transitions until the existing
`Recover` action completes it.

## Two-phase invocation

First run without `-Execute` and preserve the correction file SHA-256 reported
in `audit_receipt.sha256`:

```powershell
$plan = pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectActiveProjectRepositoryScope `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <active-unit-id> `
  -ProjectRepositoryScopeCorrection <private-correction-input.json> `
  -OutPath <project-root>\morphospace\receipts\<correction-id>.json |
  ConvertFrom-Json
$plan
```

Independently compare that hash with `Get-FileHash`, then execute the unchanged
input with the exact observed value:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectActiveProjectRepositoryScope `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <active-unit-id> `
  -ProjectRepositoryScopeCorrection <private-correction-input.json> `
  -ExpectedProjectRepositoryScopeCorrectionSha256 $plan.audit_receipt.sha256 `
  -OutPath <project-root>\morphospace\receipts\<correction-id>.json `
  -Execute
```

Run `scripts/Test-WorkflowContracts.ps1 -WorkspaceRoot
<project-root>\morphospace -SkipOwnerSelfTests` after execution. The action does
not run source validation or authorize a commit, push, release, or publication.
Run `scripts/Test-CorrectActiveProjectRepositoryScope.ps1 -SelfTest` and
`scripts/Test-TransitionLedger.ps1` after changing this action or its journal
contract.
