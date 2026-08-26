# Rusty Morphospace Project Workflow

Use this reference for portable project composition, activation, isolated
source work, iteration units, validation, boundary review, and instruction
synchronization.

## Resume And Scope

Read in this order:

1. nearest repository and project instructions;
2. `morphospace/project.spec.json`;
3. `morphospace/feature.lock.json`;
4. `morphospace/workspace.state.json`;
5. current iteration unit, when present;
6. only the event tail and receipts named by compact state;
7. the unit's instruction-impact surfaces;
8. Git status for every repository in scope.

Treat `project.spec.json` as composition authority, not module runtime
authority. Treat `feature.lock.json` as the closed permitted feature and effect
set. Treat `workspace.state.json` as a resume projection, not a replacement for
the immutable unit, event, and receipt evidence.

For an idle accepted project whose next feature needs new bounded composition,
use the dedicated preparation transaction before admission. It may add only a
typed project-level envelope and a repository-map-derived source lock; the
later unit admission must bind those artifacts and may not rediscover authority.

Work only in repositories and paths allowed by both the project and current
unit. Stop when the required change falls outside that intersection. Preserve
dirty, detached, divergent, blocked, interrupted, and historical state rather
than rewriting it.

## Closed-World Composition And Activation

Resolve owner-issued feature descriptors into an exact fingerprinted lock.
Keep descriptor filesystem locations as resolver inputs only; store portable
forward-slash references relative to `project.spec.json`. Reject absolute,
parent-traversing, and out-of-project references.

Treat absent, denied, unlisted, stale, or merely registered features as inert.
Project selection alone does not activate a run. Require the current selected
lock plus a descriptor-approved runtime input, then bind effective consumer
evidence to the project, feature, lock revision, and fingerprint.

Keep every optional family disabled by default. For downstream adoption,
select the baseline shell, name nearby optional features as disabled, and
assert at least one unrelated feature remains absent and inert.

## Exact Source And Isolation

Keep observed, claimed, validated, and accepted revisions distinct. Before
cross-repository implementation or extraction, bind clean exact commits and
trees in a source-composition lock. Prefer detached clean materializations when
live checkouts are moving.

When the repository-root `morphospace/` exists only as intentional dirty bytes
in a Git-backed source checkout, and its complete bounded live inventory
differs from the pinned tree, use `MaterializeUnpublishedPlanningAuthority`.
That derived predicate excludes published-tree projection v1-v3; caller prose
does not. Bind the complete inventory and exact `workspace.state.json` anchor,
copy no sibling bytes, install atomically into a
distinct clean planning repository, preserve the source as historical, and
leave ordinary workflow admission for later. This is not
`planning_workspace_projection.v1-v3` and grants no Git or acceptance claim.
Windows execution establishes distinct authority with volume-serial plus
FileIdInfo identities and replays destination/stage identities; namespace
aliases such as `subst` are not distinct repositories.

Separate source, build, and run identities. Use disjoint application,
client, marker, output, property, staging, and other mutable resource
identities. Treat machine-local claims as coordination only; they do not
activate features or authorize Git or device operations.

## Work-Unit Lifecycle

Allow at most one current active or validating unit. Keep inspection and
planning non-mutating; require explicit execution for an owned state
transition. Use the workflow owner's actions instead of hand-editing status,
compact state, or event history.

When a current unit exists, Ready must use the ledger's canonical v2
supersession-ID constructor before mutation and reject identities whose exact
rendering exceeds the existing 128-character event-ID contract. Withdraw only
the exact next-ready unit with `WithdrawReady`: authenticate its unique
owner-generated Ready event and transaction plus the current state/unit/event
prefix, preserve current authority and the historical Ready event, change only
`ready` to `proposed`, and deterministically recompute the queue. A withdrawn
identity is not eligible for Ready again; a revised proposal needs a new ID.

An immutable non-current/non-next in-flight pair may be interpreted through
`historical_unit_compatibility_projection.v1` only when the typed
`RecordHistoricalUnitCompatibilityProjection` action authenticates the exact
Ready/WithdrawReady and v2 supersession chains. Its mappings are closed and
tail-only; raw unit actions and commands remain unchanged, and no completion,
execution, validation, acceptance, or publication is inferred.
An exact later local closure is valid only when the owner-generated
instruction-completion, `BeginValidation`, deep-pass `RecordValidation`, and
`Accept` transactions form the complete contiguous suffix and derive the live
terminal state. The compatibility receipt never substitutes for those actions.

When a cold aggregate has immutable terminal metadata debt but the current
feature contract is sound, use only the project-local,
independently-signed `historical_validation_debt_baseline.v1` ratchet. Bind the
validator's closed dependency manifest, source composition, state/event prefix,
current bytes, and the exact sorted failure set; materialize the
content-addressed result and bind it into the validation receipt; report
debt-bearing success rather than a clean workspace.
Never baseline current, instruction, source-scope, validation, acceptance, or
tool/transport failures. Route detail to
`docs/HISTORICAL_VALIDATION_DEBT_BASELINE.md`.

For an exact `<old>-superseded-by-<new>` event, bind old independently from
event `unit_id` and new independently from target-state `current_unit`; treat
the event ID only as their exact rendering and reject delimiter ambiguity.
Require a v2 intent to hash-bind the original state plus the exact
active/validating old-unit path/document, and reject legacy or damaged bindings
before intent, artifact, torn-tail repair, projection, or event mutation.
In aggregate historical validation, evolving instruction-policy failures for a
non-current, non-next-ready raw active/validating unit may be deferred only
until that same pass authenticates the exact canonical supersession edge.
Missing or damaged evidence restores the original failures; no structural,
registry, event, or current-unit check is deferred.

If the exact replacement later terminates through typed validation failure,
admit its blocked history only after authenticating the exact v2 supersession
intent/completion and target, then the directly chained
`BeginValidation`/`validation-fail` intent and completion chains, same-unit fail
receipt, blocker/checkpoint, and terminal state/unit targets. Authenticate all
later owner transactions as a derivable suffix rather than requiring the fail
event to remain the live tail. Preserve strict v1 suffix handling. A later v2
is admissible only as the exact owner-produced old-to-ready-replacement
supersession. A later v3
transaction must be owner-produced, non-superseding, exact-property, and bind
one or two canonical ordered project/lock projections. First-seen projection
paths must be unchanged anchors; changed paths must chain an earlier target to
the next preimage and finally to live bytes. An arbitrary blocked replacement,
unknown or detached projection, damaged suffix, receipt substitution,
status-only mutation, or acceptance
inference fails closed.

Do not make that rule tolerant for history. The only supported completed
legacy-v1 target-as-event-unit fault uses the workflow owner's derived
`completed_transition_semantic_correction.v1` receipt and
`CorrectCompletedTransitionSemantics`. Require empty original receipts and
intent artifacts, authenticate both transaction chains, preserve all
historical/unit bytes, and route the procedure to
`docs/COMPLETED_TRANSITION_SEMANTIC_CORRECTION.md`.

Derive repository, path, graph, and validation scope from the unit. Keep
proposals, claims, validation results, acceptance, publication planning, and
external execution as separate facts. A passing check is evidence, not
acceptance. A prepared publication plan is not execution evidence.

Select `guard_profile` independently from `risk_tier`. Use `fast` for bounded
product work across its declared repositories and device stages, `labs` for
composition, activation, product-authority, device-policy, or routing work, and
`locked` for releases or workflow/state/validation/recovery trust-root changes.
Risk tier controls evidence depth only. Treat inferred guards on immutable
older units as compatibility; new units declare the guard explicitly.

If an exact non-passing validation attempt remains inside the same feature
unit's scope and authority, use `ReturnToActive` with the validation receipt.
Keep the same captain and retain the attempt. Use blocker recording plus
`Resume` only when work stops or current-unit authority is released. A
validation-only unit cannot convert itself into product implementation.

If the same active feature unit discovers another writable path or repository
already authorized by the project, use `AmendActiveWriteScope`. Bind the exact
project/state/unit/event inputs and complete before/after path sets, add at
least one path, preserve every prior path, and replay the dry-run amendment
hash. The transaction keeps captain/status, mutex-binds the unchanged project
spec, and performs no source, Git, build, validation, device, or remote work.
It is never a route to broaden project authority or a validation-only unit.

Before Claim, run `Inspect` with the exact consumer inventory and inputs. Read
v2 `claim_preflight.advisory_status`, its expected/completed/skipped/missing
coverage, reason codes, candidate fingerprint, and bound contract identities.
Treat `fail` as a known contradiction and `incomplete` as missing proof; never
promote either to pass. Keep this result diagnostic and non-mutating, separate
from `ready_to_claim`, until a separately reviewed shadow-evidence gate changes
Claim authority. Guard sufficiency is a distinct lifecycle declaration gate,
not a promoted advisory check: an insufficient explicit guard blocks Claim.

For an expensive execution path, bind a project-produced
`execution_preflight_observation.v1` and assert the exact non-sensitive identity
values or capabilities needed by the unit. Use it for package/application ID,
grant mode, signer fingerprint, toolchain/NDK/CLI capability, bridge/port
readiness, or source-lock identity. Claim verifies bytes and assertions only;
it does not generate the observation or execute a build/device/bridge stage.

Before an expensive reusable-contract matrix, preflight the real consumer,
iterate with focused checks, obtain independent review, freeze one candidate,
then run the final matrix once. Do not promote a single-consumer recovery to
shared infrastructure without a second consumer, neutral harness, or explicit
owner decision. After one new control-plane prerequisite on a product path, a
second mismatch is an exact blocker; return priority to the next code-bearing
product checkpoint. Update orchestration state at merge, materialization, and
handoff boundaries.

Preserve blockers and interruptions with typed, hash-bound evidence. Recovery
may update workflow state only after the external owner proves safe cleanup;
it does not silently perform Git, process, package, route, or device cleanup.

This portable workflow never grants commit, push, force-push, merge,
publication, repository-setting, or device authority. Perform those actions
only when the user and the owning workflow explicitly authorize them.
Treat `manual-owner-review` as a publication hold requiring explicit owner
review, never as push, PR, merge, release, validation, acceptance, or guard
authority.

## Validation Selection

Select the smallest tier that can prove the changed boundary:

- Use focused or Quick checks while iterating on a bounded change.
- Use Standard checks for a coherent cross-surface handoff.
- Use Deep checks for broad authority, graph, release, or device-gated
  consolidation when the risk warrants them.

When a repository retains a cumulative Standard compatibility entrypoint, run
Quick once and then invoke its explicit Standard-delta owner command. Do not
follow a passing Quick checkpoint with cumulative Standard solely to replay the
same Quick coverage.

Treat a dirty aggregate as explicit diagnostic evidence, not a prerequisite
for a clean handoff. Freeze and commit the coherent candidate, then run its
risk-selected aggregate once against the exact base. Do not run the same
aggregate before and after a commit solely to produce both dirty and clean
receipts. If a repair changes the candidate, rerun the nearest failed check
first and execute the aggregate once more for the repaired commit.

For repository CI, run feature-candidate validation from pull-request events
and retain `main` push readback. Group candidate runs by pull request so a new
revision cancels its superseded run; do not cancel `main` readback. Keep Quick
contexts required, and make a separate required Standard context execute only
its additional delta instead of replaying Quick.

Run static, schema, contract, fixture, and synthetic checks before platform or
device validation. Do not run a device suite to prove documentation or schema
changes. When device validation is actually required, route it through
`$meta-quest-workflow`.

Require validation evidence to bind exact criteria, artifacts, repository
revisions, ancestor bases, and in-scope changed paths. Revalidate before
acceptance so drift rejects. Keep acceptance under the workflow owner.

For repository CI, route proportional selection and exact-tree artifact reuse
through [Affected Validation](../../../docs/AFFECTED_VALIDATION.md). A missing
or stale reuse receipt falls back only to the current delta; Deep history stays
scheduled/manual and `pending-infra` never proves a candidate.

If a change modifies its own validation authority, use the two-PR external
validation-authority boundary. The trusted base first approves the exact
reviewed ancestor, complete path set, sizes, and hashes. A base-owned static
check then reads candidate Git objects without checkout or execution. Run
dynamic validation separately; neither static admission nor a candidate-issued
receipt is independent publication authority.

## Public And Private Boundary

Commit only portable schemas, synthetic fixtures, placeholder commands,
public upstream references, and sanitized summaries. Exclude machine paths,
private repository identities, device serials or endpoints, package and
signing identities, credentials, pairing material, generated applications,
raw logs, screenshots, captures, traces, private payload semantics, and live
project evidence.

Preserve owner evidence byte-for-byte. When a public wrapper is allowed, bind
only the owner schema and content hash plus sanitized facts; never relabel a
workflow wrapper as owner evidence.

## Instruction Synchronization

Treat authority, module layout, activation, validation, device policy,
repository routing, and public/private boundary changes as instruction-impact
changes. In the same unit, update:

- the nearest repository instructions;
- a README or router document;
- each relevant portable or local skill router.

Keep `AGENTS.md`, `SKILL.md`, and README entrypoints concise. Put detailed
procedures in linked references or runbooks. Record reviewed-without-change
surfaces explicitly when the workflow requires it; inferred graph edges do not
substitute for instruction-impact evidence.

Do not hand-edit an in-flight unit to mark planned instruction surfaces complete.
Use `CompleteInstructionSurfaces` with the dry-run unit hash, stable content-
observation hash, and exact full planned-surface ID set. The transaction may
change only those statuses and records that it executed no validation command;
ordinary validation and acceptance remain separate.

Do not hand-edit an active unit when its read-only parser/build closure has one
wrong exact identity or lacks an already project-declared parse-only
repository. Use `CorrectActiveReadOnlyDependencies` with the complete exact
before/after dependency sets, state/unit/event-ledger CAS, and one resolvable
full commit/tree for every resulting dependency. It may update only existing
verification text or add declared non-writable dependency paths; materializing
the resulting siblings and validating them remain separate owner steps.

Do not hand-edit the exact current active feature unit when one legacy string
or absent `architecture_decision` and exactly the required
`rusty-morphospace`/`system-engineering` surfaces prevent current validation.
Use only `CorrectActiveUnitContract` with its strict correction document,
project/state/raw-and-canonical-unit/ledger CAS, caller-pinned dry-run hash,
and atomic receipt/intent/completion/event transaction. Retain a legacy
selected string verbatim; add only the fixed planned `review-no-change` skill
records; preserve every other unit field and state field except the event tail.
The action does not complete instructions, execute validation, mutate source or
Git, touch a device, or authorize acceptance or publication. Route detail to
`docs/ACTIVE_UNIT_CONTRACT_CORRECTION.md`.
