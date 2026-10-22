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

## Source landing and downstream adoption

A bounded source package and a downstream product adoption unit have distinct
outcomes. Source checks, review and protected normal CI/merge can qualify and
land the source while product adoption remains pending. A package that changes
workflow or publication authority still requires its own locked owner; this
separation cannot downgrade that source work to the fast lane.

When a frozen product contract explicitly orders source publication after its
acceptance, preserve that contract and record the human's explicit superseding
decision through the stateless source-delivery disposition in
[Source-only publication](SOURCE_ONLY_PUBLICATION.md). The record changes no
product state, event, tooling pointer, source reference or acceptance status.
Preparing a disposition earns no landed-source credit. A later landed record
must authenticate the actual publication subject's checks and normal merge.
A port is a distinct source subject with an explicit review and limitations;
the built original's APK, tests and adoption evidence do not transfer to it.

## Agent and framework adaptation

Framework practices operate inside the selected owner package. Reuse its
approved objective, scope, exact checkpoints, validation route and lifecycle.
Use Superpowers design, debugging, testing and review practices where useful;
use GSD bounded phases, fresh contexts and dependency waves when they reduce
coordination. Select one execution scheduler and one isolation owner. Framework
notes are derivative navigation, not another planning or acceptance authority.
Existing user authorization and resolved decisions persist across continuation;
revisit them only when an unresolved scope, authority or evidence boundary
changes the action. Honor the user's model and reasoning settings for workers
and reviews through the live tool schema; framework examples grant no override.

Reuse suitable existing isolation, dependencies and compatible build lanes.
Choose setup and baseline checks from missing prerequisites, changed inputs or
actual uncertainty. Entering a worktree alone requires no cold build, dependency
reinstall or full suite. Verify claims with the owner's required checks and
exact evidence-reuse rules, preserving required live facts. Label executed,
reused, blocked and unattempted work separately and name material reuse misses.

Delegate coherent independent outcomes with explicit path ownership and compact
evidence returns. Keep one writer per mutable surface and order semantic
prerequisites and owner transitions. The worker owns its ordinary repair loop;
review or rerun completed work when changed inputs, failure or an unresolved
risk warrants it. Neither a new reviewer nor a handoff implies a cold baseline.

Carry the same issued original through actual exit, reap, stream EOF and semantic
outcome using its owning executor. Advisory duration and storage indicators
prompt observation or a scoped decision; they do not cancel an operation.
Explicit Stop, actual expiry, revoked authority and damaged evidence retain
their owner-defined effects. A signed lifetime still deserves review when it
prevents the intended operation. Record adjacent discoveries for later and
attempt the next supported product action after repairing the selected path.

Use only supported versioned reload boundaries for data, policy and assets.
Native, JNI, codec and lifecycle changes still cross their required source and
artifact boundaries. Runtime display selection is not source hotloading.

Keep one compact continuation with the objective, authorized stop boundary,
exact source and artifact identities, active originals and custodian, blocker,
next supported action, deferred discoveries and evidence pointers. Keep history
in its existing owner records. Close the package with its usable outcome,
remaining limits and resource custody. Preserve meaningful ignored inputs and
original evidence still authenticated by consumers before worktree archival;
use the existing cleanup and evidence-relocation contracts for retirement.

## Central issue queue

Use the existing queue published by the adopted external planning authority.
Resolve the installed work-environment source through
`references/local-work-environment.json`; its provenance does not grant authority.
Use the authority binding in the nearest owner instructions or explicit task
context. Otherwise, its root may be discovered through `repos.planning_authority`
in the work-environment clone's ignored `local/local.paths.json`. This optional
local path is navigation only. Read that authority root's `AGENTS.md` and
`README.md`, and follow their existing queue pointer. Keep private identities
and machine paths in ignored local configuration, never in portable source.

Apply three triggers through one queue writer:

- **New package:** skim relevant open items once. Keep one primary outcome and
  record selected IDs plus brief deferrals in existing owner notes. Balanced
  mode may include related work sharing actual validation with bounded cost/risk;
  user-selected fast track includes direct delivery dependencies only.
- **Concrete discovery:** deduplicate by cause. Update the existing row with
  owner, state/problem, next action, done-when and an evidence pointer; continue
  the selected product work. Add a new ID only for a distinct cause.
- **Result or handoff:** reconcile selected IDs with final PR/evidence links,
  remaining actions and limits. Keep source-landed, adoption-pending and
  runtime-proven facts separate.

If the binding is missing, conflicting or unavailable, or another writer owns
the queue, retain one small linked pending update in existing owner notes and
continue product work. Do not guess a queue, replace it with an ignored CURRENT
backlog, or infer adoption/grants from a path. Queue upkeep does not widen an
admitted scope, require a ticket per commit, rescan the full backlog, add a
validation/build gate or create another approval loop. GSD/Superpowers notes
reuse this authority and the selected owner; they are not another issue queue.

## Minimal package

Use the [central issue queue procedure](#central-issue-queue) for the three
checkpoint triggers above. Package selection does not replace owner requirements.

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

## Manual Task-Owned Scratch Cleanup

Use this playbook when the user requests cleanup, or to tidy disposable scratch
created by the current authorized task. It creates no schedule. Empty,
untracked scratch needs no Git checkpoint, archive or development-unit admission.
The direct package's source handoff checkpoints above do not apply to it. Keep
source, accepted evidence, a useful compact result, and any required rollback
artifact under their existing owner rules. Shared caches, old worktrees and
session archives use their separate cleanup routes.

1. **Inspect.** Name one exact owned scratch parent and the literal targets.
   Resolve absolute paths and require every target to be strictly beneath that
   parent. Check existing ancestors for symlinks/junctions or other reparse
   points; stop that target if its destination or ownership is ambiguous.
   Exclude volume/repository roots, Git metadata and worktree administration,
   tracked files, shared caches and retained results. Inspect hidden entries
   too. Git does not track empty directories; an empty directory does not need
   to be committed before removal.
2. **Establish quiescence.** Confirm the task's writer has exited and no other
   task is using the target. A zero-byte lock is a file, not proof of idleness:
   remove it only when its owner is known to have stopped and an exclusive
   open succeeds. If that cannot be established, retain it and continue other
   work. Nonempty files require their own explicit disposable classification.
3. **Execute narrowly.** Recheck the resolved targets and contents immediately
   before mutation. Remove verified disposable files individually and empty
   directories from the leaves upward, using native filesystem operations
   with literal paths and nonrecursive directory removal. Unexpected contents,
   path changes, locks or access errors leave the affected target in place.
   Do not use a recursive wildcard sweep or Git cleanup/reset commands.
4. **Verify.** Confirm the intended targets are absent and retained inputs are
   unchanged. Keep one short result only if it helps the current handoff; do
   not create a new cleanup ledger or archive empty scratch.

Distinguish a Git preservation check, filesystem error, owner workflow rule and
app approval rejection. Record the exact rejected operation and available
reason. A generic `blocked by policy` message does not identify Git as the cause.
Do not retry a denied deletion through another shell, API, helper or weakened
permission setting. Repository guidance cannot override app enforcement;
resolve that limitation through its actual owner. Leave denied targets intact
and continue unrelated authorized work.
