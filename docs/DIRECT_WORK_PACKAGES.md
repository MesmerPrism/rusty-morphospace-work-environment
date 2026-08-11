# Direct Work Packages

Direct work packages are the lightweight front door for routine Rusty
Morphospace work. They make scope, validation, and recovery explicit without
requiring every bounded change to enter the full autonomous-unit state machine.
They are advisory intake records, not a new source of workflow authority.

The existing lifecycle remains authoritative. This layer reads its guard
profiles, risk tiers, change categories, and aliases from
`manifests/workflow-lifecycle.portable.json`.

## Lane selection

| Intended change | Declared profile | Route |
| --- | --- | --- |
| Bounded implementation, validation, or documentation in exact repositories | `fast` | Validate the package and work directly. |
| Product authority, module layout, activation, device policy, or repository routing | `labs` | Use the package as intake, then create an autonomous unit. This is the guarded lane. |
| Release, recovery, publication-boundary, workflow, state-machine, or validation-authority work | `locked` | Use the package as intake, then create an autonomous unit with the existing locked controls. |
| Unclear or mixed scope | highest plausible profile | Escalate before mutation; downgrade only after the surfaces are understood. |

Cross-repository work is not automatically guarded. It may remain `fast` when
all repositories and base commits are declared and the change categories are
limited to bounded implementation, validation, or documentation. Select
`risk_tier` independently: guard profile controls authority, while risk tier
controls validation depth.

## Minimal package

Keep the record outside public source repositories when it contains private
intent or commands. Use public repository identities and portable relative
paths; do not store local machine paths, secrets, device identifiers, or private
evidence in a public package.

```json
{
  "schema": "rusty.morphospace.workflow.direct_work_package.v1",
  "package_id": "bounded-kiosk-filter",
  "objective": "Add and validate one bounded filter across the declared application repositories.",
  "guard_profile": "fast",
  "risk_tier": "quick",
  "change_categories": ["implementation", "validation"],
  "repositories": [
    {
      "repository": "MesmerPrism/example-application",
      "base_commit": "0123456789abcdef0123456789abcdef01234567",
      "allowed_paths": ["src/", "tests/"]
    }
  ],
  "validation": [
    "Run focused package tests",
    "Run the repository handoff check from a clean commit"
  ],
  "recovery_checkpoints": [
    "local-commit-before-handoff",
    "remote-update-before-handoff"
  ],
  "history": {
    "mode": "rebuild-first",
    "max_minutes": 20
  }
}
```

Required recovery checkpoints make ordinary Git history the recovery system.
Additional checkpoint notes are allowed, but the standard local commit and
remote update before handoff remain required.

`history.mode` is either:

- `rebuild-first`: implement from current authority first; inspect old work only
  when a specific missing behavior or regression makes that cheaper;
- `history-required`: inspect history for a named compatibility, provenance, or
  regression question before implementation.

Both modes are time-boxed. A rebuild-first search may use 0–120 minutes; a
history-required search may use 1–240 minutes. Reaching the budget without a
useful result is a reason to rebuild or explicitly revise the package, not to
continue open-ended archaeology.

## Assessment

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\Test-DirectWorkPackage.ps1 `
  -Path <direct-work-package.json>
```

The command emits a machine-readable assessment. It resolves lifecycle aliases,
computes the minimum guard profile, and reports whether direct execution is
allowed. It does not mutate Git, source files, devices, workflow state, or
remotes.

Run the self-test with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\Test-DirectWorkPackage.ps1 `
  -SelfTest
```

## Working rule

For a direct `fast` package, create a clean branch or worktree from every exact
base, make focused commits at meaningful milestones, run the declared focused
validation, update the remote before handoff, and record the accepted commit or
PR. Stop and graduate the package if the work crosses into a higher-profile
category.

After acceptance, retain the package or a concise receipt only when it improves
future routing. Cleanup and historical extraction are event-driven: revisit old
worktrees, refs, or artifacts when they obstruct a live task, consume material
resources, or answer a bounded provenance question.
