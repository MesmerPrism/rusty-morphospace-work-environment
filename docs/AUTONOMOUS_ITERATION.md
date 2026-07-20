# Autonomous Iteration

This document describes the published workflow through `0.4.0` plus the
additive `0.5.0` isolation candidate. The accepted
`0.1.0` history remains immutable; later releases must preserve accepted
event/receipt history or provide an explicit migration and rollback path.

This protocol lets an agent continue a project safely across sessions without
turning a broad roadmap into unrestricted edit authority.

## Work Unit

Every implementation slice has one `iteration-unit` record containing:

- objective and prerequisites;
- stable workflow change categories plus optional project-specific `tags`;
- allowed repositories and narrower allowed paths;
- explicit non-scope;
- acceptance proofs and validation commands;
- risk tier and device requirement;
- expected outputs;
- commit policy and push checkpoint;
- change categories and instruction impact;
- affected `AGENTS.md`, README/router, and skill surfaces, or an explicit
  reason that no instruction surface changes.
- source-composition mode and exact lock/materialization receipts when the
  unit must not follow moving working copies;
- repo path, build output, package, property/staging namespace, bridge-port,
  and headset resource requirements with claim timing.

An agent may reduce scope while working. It may not expand scope beyond the
project spec and unit without a reviewed unit update.

Use `change_categories` only for portable routing and instruction-impact
derivation. Versioned lifecycle aliases map production vocabulary to one
canonical category; unknown, duplicate, colliding, or targetless aliases fail
closed. Project-local `focused` and `skill-focused` profiles may route bounded
checks without changing accepted historical unit bytes.
semantics. Preserve domain detail such as `peer-mesh`, `binder`, or
`contract-extraction` in `tags`; do not grow the portable category registry for
each application-specific noun.

## Unit State Machine

```text
proposed -> ready -> active -> validating -> accepted
                         |          |
                         +-> blocked+
                         +-> superseded
```

At most one unit is in flight (`active` or `validating`) in a project
workspace. A blocked unit records the condition, checks attempted, and the
user or external event needed to resume. Work may continue on a different
ready unit only after workspace state is updated so there is still one current
authority.

Use the fail-closed automation `Ready` action for the proposal-review
transition. It requires every prerequisite to be accepted, appends the state
transition, and derives `next_ready_unit`; do not hand-edit a proposed unit to
make it claimable. `Ready` does not authorize implementation outside the
unit's existing repository and path allowlists.

## Instruction Synchronization

Units changing authority, module layout, feature activation, validation,
device policy, repo routing, or the public/private boundary have required
instruction impact. They cannot become `accepted` until the nearest touched
repo `AGENTS.md`, a README or router doc, and relevant skills are updated and
validated.

For an implementation-only unit with no instruction change, use
`instruction_impact: none`, leave `instruction_surfaces` empty, and record a
specific justification. See
[Instruction Synchronization](INSTRUCTION_SYNCHRONIZATION.md) for the routing
matrix. Keep entrypoints short and move detailed recipes into linked docs.

## Compact State And Event Log

`workspace.state.json` names:

- plan revision;
- current and next-ready units;
- last event;
- dirty repositories;
- blockers;
- last validation checkpoint;
- pending coordinated-push bundle.

Protocol v2 also records exact repository heads/dirty fingerprints, the last
accepted receipt, and current module/capability registries. Optional repository
checkpoints distinguish the currently observed revision from the exact
revision claimed, validated, and accepted by a composition. These are compact
current projections; append-only events remain the historical source.

When a corrective unit replaces an immutable historical unit still recorded
as `active` or `validating`, do not rewrite the old unit or event prefix.
Append one `state-transition` whose ID is exactly
`<old-unit>-superseded-by-<current-unit>`, target the old unit in `unit_id`, and
make the replacement the sole `current_unit`. Contract validation treats the
old artifact as historical only after that exact, internally consistent event;
missing units, a wrong event type, or a non-current replacement fails closed.

`iteration-events.jsonl` is append-only. Add a compact record after a state
transition, contract decision, extraction, validation result, commit, push,
promotion, or blocker change. Large logs and device artifacts remain outside
the event file; events point to sanitized receipt IDs or artifact types.

Legacy vocabulary in an immutable accepted or blocked unit requires the
explicit hash-bound contract in
[Historical Iteration-Unit Adoption](HISTORICAL_UNIT_ADOPTION.md). It is not an
ignore list and cannot admit an in-flight or newly authored unit.

## Validation Tiers

| Tier | Use | Typical evidence |
| --- | --- | --- |
| `quick` | During a small edit. | Parsing, focused unit tests, whitespace, compact-state checks. |
| `standard` | Before a local checkpoint commit. | Touched-repo checks, contract fixtures, dependency and public-boundary gates. |
| `deep` | Before a coordinated push or promotion. | Full repo checks, graph/inventory refresh where relevant, cross-consumer and integration evidence. |

Live headset work is a separate device gate. A source-only unit must not claim
device acceptance.

## Git Checkpoint Policy

- Inspect status and upstream state before editing every repository in scope.
- Commit coherent, validated slices locally; do not wait for one enormous
  cross-repo commit.
- Do not mix unrelated projects or untracked user work into a unit.
- Push only at the unit's declared checkpoint: `none`, `local-only`,
  `integration-batch`, or `release`.
- An `integration-batch` may collect several accepted units. Before pushing,
  run the deep gates named by those units and create one coordinated receipt
  listing repositories, branches, commits, validation, and rollback points.
- Update workspace state and append a push event only after the push succeeds.
- Do not accept a unit with unresolved required instruction surfaces.
- `RecordValidation` validates the referenced receipt before writing a
  checkpoint. A passing receipt covers every acceptance ID and validation
  gate, hashes each artifact, matches current repository heads and the exact
  base-to-worktree changed-path set, and keeps every path inside the unit.
  Required-device receipts name serials, prove cleanup, and carry zero bounded
  package/system fatal counts. `Accept` revalidates the same receipt so later
  drift fails closed.
- A blocker describing a partial cross-repo commit, interrupted build, or
  interrupted device run cannot recover from prose alone. Supply a local
  `interruption_receipt.v1` with hashed evidence, observed repo checkpoints,
  and kind-specific safe cleanup. Build recovery requires zero active bounded
  processes plus quarantined partial outputs; device recovery requires explicit
  serials, no remaining test packages, inactive routes, and zero bounded
  fatals. Recovery restores only workflow state.
- `Claim` normally rejects every pre-existing dirty path inside the unit
  envelope. For work demonstrably started before protocol v2, first run
  `scripts/New-InflightAdoptionReceipt.ps1 -Execute`; then pass its local
  `inflight_adoption_receipt.v1` through `-AdoptionReceipt`. The receipt binds
  the exact repository heads, path set, file/deletion state, and content hashes.
  Any later edit, missing path, extra path, or repo-head change rejects. This is
  a one-time bounded migration route, not a general dirty-work override.

### Executed push evidence

A prepared `push_bundle_plan.v1` is never proof that Git changed. It remains a
non-executing intent artifact even when its workspace transition used
`-Execute`. An authorized external operator or orchestrator records
`executed_push_receipt.v1` only after all listed remote refs are read back.
`RecordPublication` then requires complete `planned_publication_accounting.v1`
commit/unit accounting and live clean readback before it may clear the exact
pending bundle. It records workflow state only; details are in
[Planned Publication Accounting](PLANNED_PUBLICATION_ACCOUNTING.md).

The executed receipt uses one `ref_id` per branch and records full old, new,
and observed-remote revisions, whether the ref was pushed or only read back,
fast-forward ancestry evidence, passing validation references, explicit
source-first/planning-last order, `force_push_used: false`, and rollback
anchors in reverse dependency order. A rollback anchor is evidence for a
reviewed revert; it is not permission to reset a shared branch.

A branch-scoped pre-push guard must identify a protected update by Git's remote
destination ref, not by the caller's local selector. Before delegating to the
prepared-plan validator, resolve an explicit selector such as `HEAD` to the
exact attached protected branch revision and reject deletion, detachment,
branch/SHA mismatch, malformed input, or multiple protected updates.

`validated-pushed` is deliberately success-only. A partial or failed push must
remain a blocker with its completed prefix and recovery evidence; it must not
be rewritten into this receipt shape. Validate completed evidence with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-ExecutedPushReceipt.ps1 `
  -Path <project-root>\morphospace\receipts\<executed-push-receipt>.json
```

The protocol supports larger push intervals without losing local commit
history or resumption evidence.

`PreparePush` requires exactly one distinct external planning repository that
contains the active project workspace. A source-only same-ref layout is not a
valid planning-final publication topology because committing its terminal
state changes the ref it is trying to describe.

If an otherwise valid no-force source push happened before `PreparePush`, do
not reset it and do not invent a retrospective plan. Record
`unplanned_publication_closure.v1` with exact old/new/readback revisions,
ancestry, rollback, hash-bound passing validation, the pre-recovery workspace
hash, and an external observer. `ReconcilePublication` validates that closure
against a clean synchronized source worktree and mutates only the separate
planning workspace projection. The reconstruction explicitly remains distinct
from `executed_push_receipt.v1`.

### Immutable release capsules

An executed-push receipt proves a particular publication action. A sealed
`release_capsule.v1` separately defines the release subject as exact committed
revisions and trees. Validate it in `candidate-cut` mode while publishing.
Later audits use `historical-closure` mode: declared remote refs may advance
only as descendants of the pinned commit. Branch convergence and clean active
worktrees are not permanent post-release requirements.

Historical validation uses isolated clean materializations and observes active
worktree dirt only as non-payload context. If original receipt bytes are
missing or hash-mismatched, append an explicit damaged-evidence record and an
independent reconstruction; never rewrite accepted history. See
[Release Capsules And Historical Closure](RELEASE_CAPSULE_AND_HISTORICAL_CLOSURE.md).

## Multi-Repository Changes

A unit names every repository it may change. Contracts land before or with
their adapters. A coordinated receipt records dependency order and confirms
that each repository is clean or intentionally dirty afterward. One repo's
successful push is not proof that the whole batch is complete.

## Optional Automation CLI

`scripts/Invoke-WorkUnitAutomation.ps1` is the portable owner for mechanical
work-unit transitions and preparation artifacts. It supports `Inspect`,
`Ready`, `Claim`, `Resume`, `BeginValidation`, `RecordValidation`, `Accept`,
`PreparePush`, `Recover`, `ReconcilePublication`, and the narrow
`ReconcilePlanningSuffixRewrite` incident-recovery action.

The CLI is deliberately narrower than an autonomous coding agent:

- inspection and plans are the default; state changes require `-Execute`;
- it reads Git state but never runs checkout, reset, stash, commit, push, or
  force-push;
- it never runs validation commands or device commands;
- a required device unit cannot enter validation without explicit serials;
- acceptance is separate from recording a passing validation receipt;
- push preparation requires exact HEAD revisions, clean attached branches,
  no behind or divergent upstream state, and one distinct planning repository
  containing the active workspace;
- a prepared push bundle records source-first and planning-last order but has
  `execution: not-performed` and `force_push_allowed: false`.
- it never emits `executed_push_receipt.v1`; that receipt belongs to the
  externally authorized push/readback step.
- publication reconciliation consumes independently authored closure evidence,
  clears only the bound stale bundle/source projection, and never performs Git.
- planning-suffix rewrite reconciliation consumes only an exact pending bundle
  after proving the original no-force execution, the later one-path
  force-with-lease planning replacement, and unchanged source history.

Keep the local repository map outside a public project instance when its paths
identify a workstation. Start from `templates/repository-map.example.json`.
Supply exact revisions through `templates/revision-set.example.json` only
after the relevant validation has passed.

Inspection example:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action Inspect `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map>
```

Explicit claim example:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action Claim `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map> `
  -OutPath <project-root>\morphospace\receipts\<claim-receipt>.json `
  -Execute
```

Pre-protocol in-flight adoption is a separate two-step operation:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-InflightAdoptionReceipt.ps1 `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map> `
  -OutPath <project-root>\morphospace\receipts\<unit-id>-inflight-adoption.json `
  -Execute

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action Claim `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map> `
  -AdoptionReceipt receipts/<unit-id>-inflight-adoption.json `
  -Execute
```

Every action returns a validation matrix, a graph scope limited to the unit's
declared repositories and paths, and a repository-preservation report.
`Recover` only repairs an unambiguous stale current-unit pointer; it preserves
blockers and prior validation evidence. `Resume` is the explicit transition
out of `blocked`.

## Receipt-Security Corrective Units

Receipt-security units use the registry-selected, hash-pinned authority runner
and a derived v2 receipt; caller-authored receipts and ordinary v1 validation
cannot substitute. Preflight is admission only, not owner evidence or
acceptance. Read [Advanced Validation Authority](VALIDATION_AUTHORITY_ADVANCED.md)
before changing this path or running its Deep tests.

## Stop Conditions

Stop and record a blocker when:

- required work is outside allowed repositories or paths;
- an authority or public/private boundary is unclear;
- a feature would become active without a descriptor and effective receipt;
- a stable promotion lacks a second consumer or conformance harness;
- validation would require unapproved device mutation or external authority;
- existing user changes overlap the unit and cannot be preserved safely.

Run `scripts/Test-WorkUnitAutomation.ps1` after changing automation behavior.
Its temporary repositories exercise clean, dirty, hash-bound in-flight
adoption, post-receipt tampering, untracked, detached, ahead, divergent,
blocked, resumed, and interrupted states and verify that push preparation
never changes a remote.
