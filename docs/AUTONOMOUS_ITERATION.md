# Autonomous Iteration

This document describes the published workflow through `0.6.0`. The accepted
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
- an optional `work_mode`; omission preserves historical feature behavior,
  while `validation-only` is the explicit review-without-product-change mode.

An agent may reduce scope while working. It may not expand scope beyond the
project spec and unit without a reviewed unit update.

Use `change_categories` only for portable routing and instruction-impact
derivation. Versioned lifecycle aliases map production vocabulary to one
canonical category; unknown, duplicate, colliding, or targetless aliases fail
closed. Project-local `focused` and `skill-focused` profiles may route bounded
checks without changing accepted historical unit bytes or semantics. Preserve
domain detail such as `peer-mesh`, `binder`, or `contract-extraction` in
`tags`; do not grow the portable category registry for
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

A `validation-only` unit declares only the `validation` change category, uses
`instruction_impact: review`, and marks every required surface
`review-no-change`. It may run host or serial-scoped device checks. A defect
found by that unit belongs in a separately proposed feature unit rather than an
in-place scope expansion.

Use one unit captain through acceptance. Host and device stages remain in the
same unit unless write, publication, or rollback authority changes. After a
workflow-contract change, preserve a three-feature-unit stability window; see
[Workflow Stability And Feature Throughput](WORKFLOW_STABILITY.md).

## Advisory Admission Preflight And Control-Plane Budget

Run `Inspect` against the exact repository map, product inputs, read-only
dependencies, validation profiles, instruction surfaces, resources, and device
selection that a later Claim would receive. The additive v2
`claim_preflight` result reports:

- `advisory_status` as `pass`, `fail`, or `incomplete`;
- a stable candidate fingerprint and exact project/workflow/schema/validator/
  instruction-router bindings;
- the complete expected check set plus completed, skipped, and missing checks;
- stable reason codes and `state_mutation_performed: false`.

`fail` means the observed declaration contradicts a known contract.
`incomplete` means required proof or a required input is unavailable. A
skipped check must identify why it is not applicable; it is not missing proof.
`pass` means only that every current advisory check completed or was explicitly
inapplicable. The preflight does not run acceptance commands, prove product
behavior, or grant repository, publication, device, or user authority.

This is a shadow result. Keep the existing `ready_to_claim` lifecycle result
separate and keep Claim behavior unchanged. Do not make
`advisory_status: pass` a Claim requirement until the separately reviewed
promotion gate has enough real shadow evidence and a rollback decision.

Before publishing a reusable authority/workflow contract or running its final
expensive matrix, perform one bounded read-only compatibility preflight against
the real consumer inventory and state shape. Sanitize public fixtures and keep
private evidence private; generic fixtures alone are insufficient. Use focused
or Quick checks while iterating. Obtain independent review, freeze one exact
candidate, and run the owner-required final matrix once. Any later code or
contract-byte revision invalidates that matrix and requires a newly justified
run.

Do not turn a one-consumer recovery into shared infrastructure without a
second independent consumer, a neutral conformance harness, or an explicit
owner decision. A product-critical path may acquire at most one newly reviewed
control-plane prerequisite. If another workflow or contract mismatch appears,
stop with its exact bounded evidence instead of recursively inventing another
repair.

For example, a project may have its only authoritative planning bytes in an
intentionally dirty checkout. The tempting response is to invent a reusable
materialization contract immediately and then repair every mismatch found by
that contract. First preflight the exact dirty inventory and consumer state
read-only. If one bounded recovery is justified, freeze and review it. If its
execution reveals a second semantic mismatch, preserve the source, report the
blocker, and return the next available checkpoint to product code; do not grow
another general workflow layer from that one consumer.

Measure progress by owner product deltas and focused behavior tests. Cleanup,
documentation residuals, ref retirement, and unrelated workflow improvements
must not preempt the next code-bearing product checkpoint unless safety or
resource release requires it. Validate in proportion to risk and candidate
maturity; classify unrelated host failures and defer them unless they
invalidate the candidate. Refresh orchestration state at merge,
materialization, and handoff boundaries so continuation never resumes from a
stale PR, base, writer, or authority claim.

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
The generic transition ledger enforces the same edge under its workspace
mutex before staging artifacts or publishing an intent. It derives the exact
event ID from event `unit_id` (old) and target-state `current_unit` (new),
rejects repeated or endpoint-embedded delimiters, verifies the unit-path and
target unit identify the replacement, and may caller-CAS the retained old unit.
Its v2 supersession intent hash-binds the original state document and exact
active/validating old-unit path/document. Completion accepts an applied target
only from that binding and validates it before torn-tail repair or projection
mutation; legacy supersession intents fail closed.

If an already completed legacy-v1 transaction has the exact event ID above but
incorrectly recorded the replacement in `event.unit_id`, do not edit it and do
not relax this rule. Route only the narrow empty-receipt/empty-intent-artifact
fault through
[Completed-Transition Semantic Correction](COMPLETED_TRANSITION_SEMANTIC_CORRECTION.md).
Its derived receipt preserves the historical prefix and both unit files,
appends one authenticated correction event, and changes only `last_event_id`.

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

When immutable no-force execution evidence instead predates the recorded plan
timestamp and a source final is an explicitly bound merge integration that
ordinary commit projection cannot enumerate truthfully, do not loosen
`RecordPublication` or edit the evidence. Route the one matching bundle through
[`ReconcileExecutedPreparedPublication`](EXECUTED_PREPARED_PUBLICATION_RECONCILIATION.md)
after exact container, timestamp, ref, path-set, parent-order, and per-parent
projection validation. The action records the non-ordinary shape and changes
workflow state only.

An exact pending bundle that remains demonstrably unexecuted may instead use
`RetirePreparedPush`. It binds the embedded plan and preparation-event owner
containers, requires complete stable clean repository observations and fresh
remote readback, rejects remotely reachable prepared ahead revisions and every
recognized execution/publication binding, and consumes only the matching
bundle. See [Prepared Push Retirement](PREPARED_PUSH_RETIREMENT.md). This
additive route does not weaken publication, reconciliation, or recovery.

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

When the workspace was embedded in the published source and an actual pending
bundle remains, first use `planning_workspace_projection.v1` to copy its exact
published-tree bytes into one distinct external planning repository. Bind that
receipt from `unplanned_publication_closure.v2`; `ReconcilePublication` may
then mutate only the external projection. When the activity and pending-bundle
fields are null but the embedded state retains a stale dirty source head, use
`planning_workspace_projection.v2` and
`AdoptPublishedPlanningAuthority`. That action consumes exact adoption
evidence, clears only the named dirty marker, updates only the named
repository-head entry, appends one event, and performs no Git operation. See
[External Planning Projection And Historical Reconstruction](EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md).

If no published tree contains the workspace and its exact bytes exist only in
one intentionally dirty source checkout, do not fabricate a projection.
Use the separate one-time
[Unpublished Planning Authority Materialization](UNPUBLISHED_PLANNING_AUTHORITY_MATERIALIZATION.md)
contract, then perform ordinary lifecycle admission from the external planning
workspace. Materialization itself is not a transition, validation, acceptance,
or Git action.

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
`Ready`, `Claim`, `Resume`, `CompleteInstructionSurfaces`,
`CorrectActiveReadOnlyDependencies`, `CorrectActiveProjectRepositoryScope`,
`BeginValidation`,
`RecordValidation`, `Accept`,
`PreparePush`, `Recover`, `ReconcilePublication`,
`AdoptPublishedPlanningAuthority`, and the narrow
`ReconcilePublishedPrerequisiteSuffix` and `ReconcilePlanningSuffixRewrite`
publication-recovery actions. It also routes the separately bounded
`NormalizeEventLedgerPrefix` migration for exactly one leading CRLF blank
record in a protocol-v2 workspace.

The CLI is deliberately narrower than an autonomous coding agent:

- inspection and plans are the default; state changes require `-Execute`;
- instruction completion is available only to the matching active or
  validating unit; it
  requires the exact full set of currently planned surface IDs, a caller-
  replayed unit hash, and a caller-replayed stable surface-observation hash;
- active-unit read-only dependency correction requires exact state/unit and
  byte-level event-ledger CAS, full before/after sets, already-declared project
  paths, and full commit/tree identities; it never changes writable scope or
  materializes a repository;
- active project repository scope correction requires exact
  project/lock/state/unit and byte-level event-ledger CAS, is additive-only, and
  can add only exact paths already declared by the active unit; its v3 journal
  synchronizes project, feature lock, and workspace registry while preserving
  the unit;
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
- executed `PreparePush` constructs its final receipt bytes before transition
  start and installs that receipt as the transition's single owned artifact;
  the receipt is never written as an overwriteable post-transition side
  effect.
- it never emits `executed_push_receipt.v1`; that receipt belongs to the
  externally authorized push/readback step.
- publication reconciliation consumes independently authored closure evidence,
  clears only the bound stale bundle/source projection, and never performs Git.
- published-authority adoption consumes independently authored projection,
  validation, and observer evidence; it requires a clean synchronized source
  and preserves every state field except the exact named dirty marker and
  repository-head entry.
- published-prerequisite reconciliation requires the current planning remote
  to be either the exact v1 one-commit suffix or the exact v2 two-commit linear
  receipt-only correction suffix beyond the executed planning final, while
  every source ref remains clean and unchanged.
- planning-suffix rewrite reconciliation consumes only an exact pending bundle
  after proving the original no-force execution, two exact common suffix paths,
  one exact replacement-delta path, and unchanged source history.
- event-ledger prefix normalization requires an initially clean Git worktree,
  exact caller-bound repository/project/state/current-unit/ledger/tail
  identities, a dry-run intent SHA-256 pinned again for execution/recovery, and
  one `0D0A` prefix. It preserves all prior event and unit bytes, appends its
  typed event, publishes its normalized receipt only after target readback, and
  changes only `last_event_id`; all other blank records remain invalid.

Keep the local repository map outside a public project instance when its paths
identify a workstation. Start from `templates/repository-map.example.json`.
Supply exact revisions through `templates/revision-set.example.json` only
after the relevant validation has passed.

Complete declared instruction surfaces with a two-phase transaction. First
inspect the exact target and retain the returned values:

```powershell
$plan = pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CompleteInstructionSurfaces `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map> `
  -InstructionCompletionId <completion-id> |
  ConvertFrom-Json
```

Then replay its exact in-flight-unit hash, stable observation hash, and every
opaque planned-surface ID:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CompleteInstructionSurfaces `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map> `
  -InstructionCompletionId <completion-id> `
  -InstructionSurfaceIds $plan.instruction_surface_completion.surfaces.surface_id `
  -ExpectedUnitSha256 $plan.instruction_surface_completion.expected_unit_sha256 `
  -ExpectedInstructionObservationSha256 $plan.instruction_surface_completion.observation_sha256 `
  -OutPath <project-root>\morphospace\receipts\<completion-id>.json `
  -Execute
```

The action resolves every declared surface through the bound repository map,
leases and hashes the files across repeated observations, and changes only
currently `planned` surface statuses to `complete`. All planned surfaces must
be named; missing, extra, duplicate, stale, moved, or changed surfaces fail.
The receipt and event are installed in the same transition. The action records
`validation_commands_executed: false`: later validation and `Accept` remain
separate gates.

When an active unit's admitted build or parser cannot run because its read-only
dependency declaration has a wrong exact identity or omits an already
project-declared parse-only repository, use the separate two-phase
`CorrectActiveReadOnlyDependencies` action. It is deliberately not a generic
unit amendment. See
[Active Read-Only Dependency Correction](ACTIVE_READ_ONLY_DEPENDENCY_CORRECTION.md)
for the strict correction document, canonical verification text, dry-run hash
replay, and transaction invariants.

When an active unit already declares an exact writable path but the matching
project repository allow-list omits it, use the separate two-phase
`CorrectActiveProjectRepositoryScope` action. It is additive-only, cannot
broaden a unit path, and carries the project spec plus feature lock as
recoverable transition-ledger v3 projections. See
[Active Project Repository Scope Correction](ACTIVE_PROJECT_REPOSITORY_SCOPE_CORRECTION.md)
for its exact-CAS input and dry-run hash replay.

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

Exact event-ledger prefix normalization is documented separately because it is
a migration, not an ordinary unit action:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action NormalizeEventLedgerPrefix `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -LedgerPrefixNormalizationId <normalization-id> `
  -ExpectedRepositoryHead <40-character-head> `
  -ExpectedProjectSha256 <64-character-project-file-sha256> `
  -ExpectedStateSha256 <64-character-state-file-sha256> `
  -ExpectedUnitSha256 <64-character-unit-file-sha256> `
  -ExpectedEventsSha256 <64-character-event-ledger-sha256> `
  -ExpectedEventsLength <event-ledger-byte-length> `
  -ExpectedEventTailId <event-tail-id> `
  -Timestamp <strict-utc-timestamp>
```

This is a dry run until `-ExpectedIntentSha256
<reported-intent-sha256> -Execute` is added. Repeat that exact caller-pinned
executed command to recover an incomplete intent; a committed completion
rejects replay.
See [Event-Ledger Prefix Normalization](EVENT_LEDGER_PREFIX_NORMALIZATION.md).

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

Core `work_unit_automation_receipt.v1` actions return a validation matrix, a
graph scope limited to the unit's declared repositories and paths, and a
repository-preservation report. Specialized additive actions that return the
strict `work_unit_automation_receipt.v2` shape instead carry its compact
preservation and audit-receipt fields; consumers must branch on the receipt
schema rather than assume the v1 matrix and graph fields are universal.
Transition repair accepts only a strict UTF-8, duplicate-key-free v1 event
whose transaction identity, canonical body, sequence, immediate predecessor,
and tail position match the retained intent. The same placement is
re-authenticated before event append and completion; a same-ID event elsewhere
in the ledger is not repair authority. Every retained ledger prefix entry must
also satisfy the exact v1 schema, unique identity, contiguous sequence, and
non-regressing invariant timestamp before it can supply a predecessor or tail.
The proposed event itself must use a strict invariant timestamp and must not
precede the authenticated tail; both start and repair prove this under the
workspace mutex before publishing an intent or changing any projection.
Each intent also binds the exact pre-append ledger byte length and SHA-256.
Repair accepts an authenticated torn suffix only when it is a strict prefix of
the one canonical event line, truncates to that bound, and then appends exactly
once. A workspace may have only one incomplete transition intent; later
transitions wait for its explicit repair. Transaction artifacts use
create-new, transaction-scoped staging files, reject occupied, duplicate,
case-alias, projection, ledger, intent, completion, and stage targets before
intent publication, and move into their final targets before projections.
`Recover` only repairs an unambiguous stale current-unit pointer; it preserves
blockers and prior validation evidence. `Resume` is the explicit transition
out of `blocked`.

`ResolveBlocker` is a separate product-neutral action for one exact blocker on
the current active unit. It validates `blocker_resolution_receipt.v1`, rechecks
hash-bound evidence, repository heads, and exact dirty source bytes immediately
before transition, preserves every other blocker and workflow projection, and
uses state/unit/event-tail CAS. See
[Generic Blocker Resolution](BLOCKER_RESOLUTION.md).

Use `CorrectResolvedBlockerEvidence` only when the target blocker remains
absent and the immutable historical resolution transaction is valid, but its
broader complete-resolution claim needs fresh evidence. The correction binds
the original event/receipt/intent/completion hash chain, current repository
heads/source bytes, and every live blocker. It changes only `last_event_id`,
appends one generic transition, fails closed on damaged retained correction
evidence, and rejects replay by stable identity or canonical hash. See
[Blocker Resolution Correction](BLOCKER_RESOLUTION_CORRECTION.md).

Use `CorrectHistoricalBlockerResolutionIntentBinding` only for the independently
verified legacy terminal-newline fault: the retained historical resolution
receipt and intent end in CRLF, and removing only each terminal carriage return
reproduces the intent-owned receipt and completion-recorded intent hashes.
The correction may be owned by a different current active unit, but binds that
unit's full state/unit/event-ledger CAS, preserves all blockers and historical
bytes, and changes only `last_event_id`. See
[Historical Blocker-Resolution Intent-Binding Correction](HISTORICAL_BLOCKER_RESOLUTION_INTENT_BINDING_CORRECTION.md).

Use `CorrectCompletedTransitionSemantics` only for the single documented
completed legacy-v1 target-as-event-unit fault. The original transition must
remain state/ledger tail while the inspected receipt is built. Workflow
contracts project the effective old unit only from an installed correction
whose shared verifier authenticates the original prefix, original
intent/completion, correction intent/completion, and sole receipt bytes. See
[Completed-Transition Semantic Correction](COMPLETED_TRANSITION_SEMANTIC_CORRECTION.md).

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
