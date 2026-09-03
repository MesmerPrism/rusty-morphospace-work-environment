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
- guard profile, risk tier, and device requirement;
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
proposed -> ready -> active <-> validating -> accepted
                         |          |
                         +-> blocked+
                         +-> superseded
```

At most one unit is in flight (`active` or `validating`) in a project
workspace. A blocked unit records the condition, checks attempted, and the
user or external event needed to resume. Work may continue on a different
ready unit only after workspace state is updated so there is still one current
authority.

For an in-scope feature correction, `ReturnToActive` validates and retains a
non-passing `validation_receipt.v1`, changes `validating` back to `active`, and
keeps the same `current_unit`. It does not create a blocker or release the unit
captain. Use the existing non-passing `RecordValidation` path when the result is
a genuine blocker, requires another owner, or should release current-unit
authority. Validation-only units cannot use `ReturnToActive`; a discovered
product defect becomes a separately proposed feature unit.

## Guard Profiles

`guard_profile` selects change authority; `risk_tier` independently selects
validation depth. A fast unit may still require deep evidence, and a locked
unit may use focused checks while iterating before its final matrix.

- `fast` is the default shape for bounded implementation, validation, or
  documentation work. It may span the unit's declared repositories, host and
  device stages, and local or integration checkpoints, but not a release or
  change to product/workflow authority.
- `labs` covers module/activation changes, product authority, device policy,
  and repository routing without release or workflow trust-root authority.
- `locked` is required for a `release` checkpoint and for public/private
  boundary, workflow automation, state-machine, validation-routing, or recovery
  changes.

New units declare the profile explicitly. Immutable units that predate the
field remain readable through `quick -> fast`, `standard -> labs`, and
`deep -> locked` inference; inference is compatibility, not permission to omit
the field from new work.

Use the fail-closed automation `Ready` action for the proposal-review
transition. It requires every prerequisite to be accepted, appends the state
transition, and derives `next_ready_unit`; do not hand-edit a proposed unit to
make it claimable. `Ready` does not authorize implementation outside the
unit's existing repository and path allowlists. When a current unit exists,
Ready calls the same canonical supersession-ID constructor as the v2 ledger
and rejects an ID beyond the existing 128-character contract before writing.
Use `WithdrawReady` only to return the exact next-ready unit to `proposed`:
the owner authenticates its unique Ready event and intent/completion, CAS-binds
the current state/unit/ledger prefix, preserves current authority and the
original event, then deterministically derives the remaining queue. The
withdrawn identity is not reusable; create a new identity for a revision.

## Instruction Synchronization

Units changing authority, module layout, feature activation, validation,
device policy, repo routing, or the public/private boundary have required
instruction impact. They cannot become `accepted` until the nearest touched
repo `AGENTS.md`, a README or router doc, and relevant skills are updated and
validated.

Derive a complete but minimum surface set from the unit's routing. Do not churn
every installed skill because one router changed; use `instruction_impact: none`
or an exact `review-no-change` surface when the unit does not change that
owner's instruction contract.

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
- the explicit or compatibility-inferred guard profile and whether it is
  sufficient for the declared authority category and push boundary.
- an optional hash-bound `execution_preflight` observation plus exact value and
  capability assertions required before Claim.

`fail` means the observed declaration contradicts a known contract.
`incomplete` means required proof or a required input is unavailable. A
skipped check must identify why it is not applicable; it is not missing proof.
`pass` means only that every current advisory check completed or was explicitly
inapplicable. The preflight does not run acceptance commands, prove product
behavior, or grant repository, publication, device, or user authority.

The v2 compatibility and coverage checks remain a shadow result. Keep their
`advisory_status` separate from `ready_to_claim`; do not make advisory pass a
Claim requirement until a separately reviewed promotion gate has enough real
shadow evidence and a rollback decision. Explicit guard sufficiency is the one
separate lifecycle declaration gate: an insufficient explicit guard adds a
claim issue immediately because the unit is requesting authority it does not
declare.

Use `execution_preflight` when the expensive path depends on runtime inputs that
ordinary file/tool presence cannot prove: package or application identity,
grant mode, signer/keystore fingerprint, CLI or NDK capability, bridge/port
availability, or an exact source-lock identity. The owning project produces a
small `execution_preflight_observation.v1`; the unit binds its SHA-256 and names
only the values/capabilities it needs. Claim reads and checks the observation
but does not run its producer, build, device, or bridge. Keep secrets out of the
observation; record only non-sensitive identities, fingerprints, and capability
results.

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

## Canonical Text Bytes And Signing Preflight

Treat raw bytes as evidence. Line-ending policy is repository-owned and
additive: inventory the real tracked tree first and resolve that repository's
divergent, dirty, or local/remote-tip-mismatched legacy refs. When the tracked
text blobs already satisfy the policy, `.gitattributes` may cover that proven
text set with explicit binary exceptions. Otherwise enroll exact text paths in
reviewed tranches. Covered text is strict UTF-8 without a BOM and LF-only.
Binary or intentionally preserved historical content stays byte-exact with
`-text`. An unenrolled path is not silently canonicalized and must not be
presented as covered.

Do not introduce a blanket text rule when it would rewrite existing history or
turn a bounded policy change into repository-wide content churn. Preserve
historical blob bytes, explicitly name each first tranche, and treat a later
conversion as its own reviewed owner change with pre/post hashes and rollback.
Editor defaults may help authors, but Git attributes plus raw-byte validation
define the contract; `core.autocrlf` is never authority.
Validate adoption in a fresh clean checkout. Refresh an older working-tree
presentation only after proving it clean; never overwrite or normalize a dirty
checkout merely to satisfy the policy.

Before hashing, signing, or publishing a request or receipt, run the byte
preflight on the exact input:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-CanonicalTextBytes.ps1 `
  -EvidencePath <exact-evidence-path>
```

CRLF, mixed endings, a UTF-8 BOM, lone carriage returns, invalid UTF-8, and
binary bytes fail with stable reason codes. The signing helper performs this
check before it opens the owner policy or signing key. It never repairs or
normalizes the input. The request producer emits LF deterministically; existing
signed comments and their historical request bytes remain verified under their
original canonical payload semantics and are never rewritten. The repository
self-test also proves that explicitly
covered LF text and byte-exact legacy/binary files have identical bytes under
supported `core.autocrlf=true` and `core.autocrlf=false` checkouts.

This contract does not rewrite commits, reinterpret historical hashes, decide
whether a legacy branch is wanted, or authorize a signature, merge,
publication, ref deletion, or local cleanup. Repository-lifecycle disposition
and owner authority remain separate gates.

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

If immutable non-current/non-next in-flight history contains exactly the
closed compatibility debt defined by
`historical_unit_compatibility_projection.v1`, generate the receipt with
`New-HistoricalUnitCompatibilityProjection.ps1` and record it through
`RecordHistoricalUnitCompatibilityProjection`. The owner action authenticates
the exact Ready-to-WithdrawReady and v2 supersession chains, preserves both raw
units and every state field except `last_event_id`, and projects no completion,
execution, validation, acceptance, currentness, or publication authority.
After recording, an exact local closure may follow only as the contiguous
owner-produced instruction-completion, `BeginValidation`, deep-pass
`RecordValidation`, and `Accept` transaction suffix. Authenticate every
preimage, receipt, event, target, and final live byte; the projection itself
still infers none of those lifecycle outcomes.

A supersession replacement whose typed validation result is `fail` is a narrow
historical terminal case, not a generic permitted blocked status. Authenticate
the exact v2 supersession intent/completion and target state/unit, then require
the directly chained `BeginValidation` and `validation-fail` ledger records and
their intent/completion chains. Bind their prefix preimages, event identity,
same-project/unit fail receipt, validation checkpoint, owner blocker, blocked
unit target, cleared current/next target, and unchanged acceptance projection.
Then authenticate each later event transaction as a continuation of the prior
state target and derive the final live state plus every touched live unit. Keep
v1 suffix handling unchanged. Admit a suffix intent v2 only as the exact
owner-produced old-to-ready-replacement supersession, with strict state/unit
preimages, endpoints, target status, and unchanged acceptance. Admit a suffix
intent v3 only after the fail
target, never as supersession: require its exact known property set, one or two
canonical unique ordinal-ordered `feature.lock.json`/`project.spec.json`
projections, exact embedded schema/project/hash bindings, canonical-base64
artifacts with case-insensitively unique canonical paths and exact event-receipt
coverage, live artifact bytes, and completion binding. A path without an earlier authenticated suffix projection
must be unchanged (`pre_sha256 == target_sha256`); a later changed projection
must chain the earlier target into its preimage, and the last target must derive
the live document. The v3 state may advance only `last_event_id`, while the
same active captain, status, current/next, and acceptance projection remain.
This lets a later unit become current or accepted without requiring the fail
event to remain the live tail. Missing or damaged links, receipt substitutions,
detached suffixes, status-only mutation, non-derived live projections, unknown
v3 fields or paths, and any acceptance inference fail closed. The ordinary
active, validating, and accepted replacement rules remain unchanged when no
terminal-fail history exists.

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
device acceptance. Validation tiers do not grant authority: select authority
with `guard_profile` and evidence depth with `risk_tier`.

Run focused checks first, then only the Quick and Standard delta selected by
[Affected Validation](AFFECTED_VALIDATION.md). The hosted-observer boundary is
defined once in [Autonomous Liveness And Hosted Execution](#autonomous-liveness-and-hosted-execution).

## Git Checkpoint Policy

- Inspect status and upstream state before editing every repository in scope.
- Commit coherent, validated slices locally; do not wait for one enormous
  cross-repo commit.
- Do not mix unrelated projects or untracked user work into a unit.
- Push only at the unit's declared checkpoint: `none`, `local-only`,
  `integration-batch`, `manual-owner-review`, or `release`.
- `manual-owner-review` holds publication until an explicit owner review. It
  does not itself authorize a push, PR, merge, release, validation result,
  acceptance transition, guard change, or any remote mutation.
- A `release` checkpoint requires `guard_profile: locked`; fast and labs units
  may still make regular local commits and use declared integration batches.
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

For a normal linear publication whose source refs and one planning
receipt-only commit already match the immutable execution/accounting evidence,
but whose planning worktree contains exactly the five transaction-owned
`PreparePush` paths, use only the externally signed
[`ReconcilePreparedPushTransactionSuffix`](PREPARED_PUSH_TRANSACTION_SUFFIX_RECONCILIATION.md)
route. It CAS-binds the exact unit, state, ledger, plan, transition, receipts,
refs, suffix commit, and dirty paths; consumes only the matching pending bundle;
and changes no Git, evidence bytes, timestamps, validation, acceptance, or
publication authority. Another bundle requires another signed owner scope.

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
`Ready`, `WithdrawReady`, `Claim`, `Resume`, `CompleteInstructionSurfaces`,
`AdmitDevelopmentUnit`, `AmendActiveWriteScope`, `FreezeCandidate`,
`RematerializeValidatingCandidate`,
`MaterializeInheritedCandidate`, `CorrectActiveReadOnlyDependencies`,
`CorrectActiveProjectRepositoryScope`, `CorrectActiveUnitContract`,
`RecordHistoricalUnitCompatibilityProjection`,
`BeginValidation`, `ReturnToActive`,
`RecordValidation`, `Accept`,
`PreparePush`, `Recover`, `ReconcilePublication`,
`AdoptPublishedPlanningAuthority`, and the narrow
`ReconcilePublishedPrerequisiteSuffix` and `ReconcilePlanningSuffixRewrite`
publication-recovery actions. It also routes the separately bounded
`NormalizeEventLedgerPrefix` migration for exactly one leading CRLF blank
record in a protocol-v2 workspace.

The CLI is deliberately narrower than an autonomous coding agent:

- inspection and plans are the default; state changes require `-Execute`;
- validating-candidate rematerialization requires a clean exact pre-existing
  repository mapping, full raw/canonical workspace and predecessor CAS, and a
  distinct lineage-bound source lock/freeze. It preserves validating/current
  ownership, clears only the stale selector, and performs no Git, build,
  device, validation, acceptance, or publication work;
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
- active-unit contract correction requires the exact current active feature
  unit, project/state/raw-and-canonical-unit/ledger CAS, one legacy
  architecture-decision conversion, and only the two fixed planned skill
  surfaces; it cannot change source scope, execute validation, complete
  instructions, or authorize acceptance or publication;
- active write-scope amendment requires the exact current active feature unit,
  project/state/unit/event CAS, complete before/after paths, at least one
  project-approved addition, and dry-run input-hash replay; it retains captain,
  status, project authority, and every unit field except `allowed_repositories`;
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

When one exact current active feature unit has a legacy string or absent
architecture decision and wholly lacks the currently required
`rusty-morphospace` and `system-engineering` skill surfaces, use the separate
two-phase `CorrectActiveUnitContract` action. It preserves the legacy selected
string verbatim, adds only fixed `review-no-change`/`planned` records, and
requires the existing current-unit compatibility rule before transaction. See
[Active Unit Contract Correction](ACTIVE_UNIT_CONTRACT_CORRECTION.md) for its
strict input, raw/canonical CAS, and dry-run hash replay.

When the same active feature work discovers another writable path or
repository that the project already authorizes, use the separate two-phase
`AmendActiveWriteScope` action. It keeps the captain and status, is
additive-only, and cannot expand project authority. See
[Active Write-Scope Amendment](ACTIVE_WRITE_SCOPE_AMENDMENT.md) for the input,
dry-run replay, transaction, and negative boundaries.

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
out of `blocked`. `ReturnToActive` is the distinct same-owner transition from
`validating` to `active`; it requires a non-passing exact-scope validation
receipt and preserves that attempt without manufacturing a blocker.

`RematerializeValidatingCandidate` is a same-state correction for an exact
already-validating admitted unit whose frozen product source was superseded by
an independently adopted descendant. It keeps the unit and captain
`validating`, retains every predecessor byte, installs exactly one successor
source lock and one lineage-bearing candidate freeze through the transition
ledger, and atomically removes the stale normal-validation selection. The
repository map must already resolve clean exact commit/tree materializations;
the action never fetches or checks out. A later already-validating
`BeginValidation` may bind a new create-new Quick selector only after the full
successor freeze is revalidated. See
[Validating Candidate Rematerialization](VALIDATING_CANDIDATE_REMATERIALIZATION.md).

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

## Autonomous Liveness And Hosted Execution

Inspection, a progress update, and a partial fixture are intermediate evidence,
not a terminal outcome. When the next action is already authorized and remains
inside the current unit, take the least-risk action first: read-only work, then
bounded version-control-recoverable work. Re-prompt only for a new scope or
authority, destructive or unbounded remote change, private/public uncertainty,
wrong or unapproved device/owner, or ambiguous or fabricated evidence.

Use established fixture helpers rather than a standalone synthetic harness that
can shadow canonical resolvers. If a public fixture unloads a test-local module,
re-import it and assert helper availability before the aggregate. A wrapper for
a locally launched child retains its terminal result and output and owns that
child to terminal; hosted observation is not local-child ownership.

The authoritative affected-validation owner for this observer contract is the
adopted commit `939df8405f26f695978c69d56ef0d7f60071fbde`, tree
`2f1f5c23ae38e8dce2e8adf152f6912a02db688f`:

- owner documentation `docs/AFFECTED_VALIDATION.md`, Git blob
  `314bee780e1630fc74a374d39e82045f6f99c4de`, raw SHA-256
  `3f70a39eb475e9a53ec8cd84eff659432fa171205a01c2b7e636338f1e3da43c`;
- schema `schemas/affected-validation-infrastructure-v1.schema.json`, identity
  `rusty.morphospace.workflow.affected_validation_infrastructure.v1`, Git blob
  `4d5e64b24241860c4fb5b5ceb7569a7a7364c225`, raw SHA-256
  `b6169f58d6199c306a748d0ca8712ca9a74805b111fba56434077e862c1bf27e`;
- producer-validator `scripts/Test-AffectedValidationInfrastructure.ps1`, Git
  blob `e0646acd6f33467922f2cf0aeee249c5c56e265e`, raw SHA-256
  `01fcee6043c0f20ee27357300ca5d5c96f87d167f32093896cb5586bfe1f5f33`.

Those owner bytes, not this runbook, define classification and evidence
semantics. The infrastructure record permits only `ready` or `pending-infra` at
pre-job attempts 0 or 1. `infra-fail` and `code-fail` belong only to bounded-child
evidence after the affected-validation owner executes a bound check. Observer
routing neither relabels hosted observations nor invents `unknown` or terminal
states. Queued or zero-job observation is not a pass, failure, rerun, or
full-history substitute. A later owner revision must replace the complete
documentation/schema/producer binding; matching paths alone are insufficient.

Before observing an external run, fix a finite per-observer deadline or maximum
poll count and a total observer-chain limit of two observers. A `pending-infra`
transfer is valid only when it binds all three canonical owner identities above;
the unique replay identity
`repository/run-id/run-attempt/infrastructure-attempt`; and the observed
state/timestamps plus next observer. The receiver rejects a repeated replay
identity, a non-`pending-infra` record, missing validation binding, or a chain
index outside 0–1. Each transfer consumes one of the two total observer slots;
it cannot reset another observer's elapsed budget. Observer routing does not
extend the affected-validation evidence schema: absent a host-owner typed
envelope that binds this identity and validates the canonical record, stop
rather than transfer. A valid routing record is only an observation cue: it
claims neither pass/fail, rerun, full-history reuse, acceptance, nor publication.
On expiry, preserve the exact run identity and request the typed next observation;
do not speculate with comments, settings, branch changes, or reruns. These
liveness rules do not relax the hard stops below.

## Stop Conditions

Stop and record a blocker when:

- required work is outside allowed repositories or paths;
- an authority or public/private boundary is unclear;
- a feature would become active without a descriptor and effective receipt;
- a stable promotion lacks a second consumer or conformance harness;
- validation would require unapproved device mutation or external authority;
- existing user changes overlap the unit and cannot be preserved safely.

Run `scripts/Test-WorkflowContracts.ps1 -StandardDeltaOnly` after changing
automation behavior.
Its temporary repositories exercise clean, dirty, hash-bound in-flight
adoption, post-receipt tampering, untracked, detached, ahead, divergent,
blocked, resumed, and interrupted states and verify that push preparation
never changes a remote.
