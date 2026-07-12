# Autonomous Iteration

This document describes the `0.2.0` portable workflow release. The accepted
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

An agent may reduce scope while working. It may not expand scope beyond the
project spec and unit without a reviewed unit update.

Use `change_categories` only for portable routing and instruction-impact
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
accepted receipt, and current module/capability registries. These are compact
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

The executed receipt uses one `ref_id` per branch and records full old, new,
and observed-remote revisions, whether the ref was pushed or only read back,
fast-forward ancestry evidence, passing validation references, explicit
source-first/planning-last order, `force_push_used: false`, and rollback
anchors in reverse dependency order. A rollback anchor is evidence for a
reviewed revert; it is not permission to reset a shared branch.

`validated-pushed` is deliberately success-only. A partial or failed push must
remain a blocker with its completed prefix and recovery evidence; it must not
be rewritten into this receipt shape. Validate completed evidence with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-ExecutedPushReceipt.ps1 `
  -Path <project-root>\morphospace\receipts\<executed-push-receipt>.json
```

The protocol supports larger push intervals without losing local commit
history or resumption evidence.

## Multi-Repository Changes

A unit names every repository it may change. Contracts land before or with
their adapters. A coordinated receipt records dependency order and confirms
that each repository is clean or intentionally dirty afterward. One repo's
successful push is not proof that the whole batch is complete.

## Optional Automation CLI

`scripts/Invoke-WorkUnitAutomation.ps1` is the portable owner for mechanical
work-unit transitions and preparation artifacts. It supports `Inspect`,
`Ready`, `Claim`, `Resume`, `BeginValidation`, `RecordValidation`, `Accept`,
`PreparePush`, and `Recover`.

The CLI is deliberately narrower than an autonomous coding agent:

- inspection and plans are the default; state changes require `-Execute`;
- it reads Git state but never runs checkout, reset, stash, commit, push, or
  force-push;
- it never runs validation commands or device commands;
- a required device unit cannot enter validation without explicit serials;
- acceptance is separate from recording a passing validation receipt;
- push preparation requires exact HEAD revisions, clean attached branches,
  and no behind or divergent upstream state;
- a prepared push bundle records source-first and planning-last order but has
  `execution: not-performed` and `force_push_allowed: false`.
- it never emits `executed_push_receipt.v1`; that receipt belongs to the
  externally authorized push/readback step.

Keep the local repository map outside a public project instance when its paths
identify a workstation. Start from `templates/repository-map.example.json`.
Supply exact revisions through `templates/revision-set.example.json` only
after the relevant validation has passed.

Inspection example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action Inspect `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map>
```

Explicit claim example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
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
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-InflightAdoptionReceipt.ps1 `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map> `
  -OutPath <project-root>\morphospace\receipts\<unit-id>-inflight-adoption.json `
  -Execute

powershell -NoProfile -ExecutionPolicy Bypass `
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

A unit tagged `receipt-security` must not use a hand-authored
`validation_receipt.v1`. It requires a registry-selected, tracked owner
validator, a fresh content/ownership observation, typed per-criterion owner
evidence, and a derived `validation_receipt.v2`. Validator execution happens
from a closed input room; registry byte, closure, output-limit, mutation, and
no-device policies are rechecked before the receipt is accepted. A pre-existing
dirty instruction file is baseline input, never current-unit attribution. If
the unit adds routing to that file, declare its exact shared integration rather
than absorbing the prior work.

For this stricter path, `RecordValidation -Execute` invokes the migrated,
hash-pinned authority runner itself. It supplies a fresh 32-byte execution
nonce and accepts the resulting v2 receipt only when that exact nonce is bound
to the authority execution record. Supplying a prewritten v2 receipt, a
different runner path, or caller-selected runner switches is rejected. A
closed room may carry explicitly listed historical Git blobs when a static
gate verifies historical object IDs; those blobs are copied into a local,
sealed object store and are fingerprinted separately from the live repository.

WF-005 is also selected by its immutable project/unit identity while this
one-time corrective migration is active. Removing its descriptive tag cannot
downgrade it to the generic v1 receipt path.

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
