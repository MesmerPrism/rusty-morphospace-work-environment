# Active Read-Only Dependency Correction

`CorrectActiveReadOnlyDependencies` is the narrow transactional route for an
already-active unit whose build or workspace parser needs a corrected exact
read-only dependency closure. It is not a generic `AmendUnit` action.

Use it only when the unit remains the exact `workspace.state.json.current_unit`
with status `active`. A validating, terminal, stale, or non-current unit is
rejected. If source scope, acceptance, validation, writable repositories, or
any other unit field must change, stop and admit a corrective or successor unit
through the normal owner workflow.

## Correction Contract

Start from
[`active-read-only-dependency-correction.example.json`](../templates/active-read-only-dependency-correction.example.json)
and validate it against
[`active-read-only-dependency-correction-v1.schema.json`](../schemas/active-read-only-dependency-correction-v1.schema.json).
Keep machine paths and private project identities in the adopting project's
private or ignored control area; the installed transaction receipt belongs to
that project's own authority boundary.

The correction binds:

- the exact project, unit, active status, and current-unit identity;
- canonical pre-state and pre-unit SHA-256 values;
- the exact event-ledger byte hash, byte length, and tail event;
- the complete current and resulting `read_only_dependencies` arrays;
- one full Git commit and tree identity for every resulting dependency; and
- a role of `exact-build-pin` or `workspace-parse-only` for each identity.

The `after` dependencies and `repository_identities` arrays must be ordered by
`repo_id`. Dependency paths must be canonical, duplicate-free,
project-declared paths. Existing dependency path order is preserved exactly.
Every `after[*].verification` value is exact and mechanical:

```text
Exact Git revision <revision> with tree <tree>; role <role>.
```

The action may update only the `verification` text of an existing dependency.
It may add a new dependency only when its repository and every path are already
declared in `project.spec.json`. It cannot remove a dependency, change an
existing dependency's paths or purpose, or make one repository both writable
and read-only.

The local repository map must contain each resulting dependency as a `source`
repository. The action resolves every full commit object and recomputes its
tree; it does not require or change the mapped worktree's current branch or
HEAD. Materializing or switching a sibling worktree to those identities is a
later owner operation.

## Two-Phase Invocation

The correction input must be distinct from the immutable output receipt. First
run the exact plan and retain its file hash:

```powershell
$plan = pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectActiveReadOnlyDependencies `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <active-unit-id> `
  -RepoMapPath <local-repository-map> `
  -ReadOnlyDependencyCorrection <private-correction-input.json> `
  -OutPath <project-root>\morphospace\receipts\<correction-id>.json |
  ConvertFrom-Json
```

Review that `executed` is `false`, all preservation flags are `false`, and
`audit_receipt.sha256` equals the exact input-file hash. Then replay that hash:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectActiveReadOnlyDependencies `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <active-unit-id> `
  -RepoMapPath <local-repository-map> `
  -ReadOnlyDependencyCorrection <private-correction-input.json> `
  -ExpectedReadOnlyDependencyCorrectionSha256 $plan.audit_receipt.sha256 `
  -OutPath <project-root>\morphospace\receipts\<correction-id>.json `
  -Execute
```

Execution rechecks all Git objects, then the transition ledger enforces the
exact state, unit, ledger hash/length/tail CAS under its workspace mutex. The
single transaction changes only the unit's `read_only_dependencies` and
`state.last_event_id`, appends one event, and installs the exact correction
input as its receipt. It does not create worktrees, change Git state, run builds
or validation, use devices, contact remotes, or grant publication authority.
It also preserves the active unit and state document's existing schema shape;
schema migration is not implied by this correction.

Afterward, the project owner separately materializes the exact sibling
identities, captures a `read_only_dependency_closure.v1`, and runs the unit's
already-admitted validation. Run
`scripts/Test-CorrectActiveReadOnlyDependencies.ps1 -SelfTest` after changing
this action or its schema.
