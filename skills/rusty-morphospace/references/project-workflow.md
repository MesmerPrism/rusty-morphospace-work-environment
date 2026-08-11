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

For an exact `<old>-superseded-by-<new>` event, bind old independently from
event `unit_id` and new independently from target-state `current_unit`; treat
the event ID only as their exact rendering and reject delimiter ambiguity.
Require a v2 intent to hash-bind the original state plus the exact
active/validating old-unit path/document, and reject legacy or damaged bindings
before intent, artifact, torn-tail repair, projection, or event mutation.

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

## Validation Selection

Select the smallest tier that can prove the changed boundary:

- Use focused or Quick checks while iterating on a bounded change.
- Use Standard checks for a coherent cross-surface handoff.
- Use Deep checks for broad authority, graph, release, or device-gated
  consolidation when the risk warrants them.

Treat a dirty aggregate as explicit diagnostic evidence, not a prerequisite
for a clean handoff. Freeze and commit the coherent candidate, then run its
risk-selected aggregate once against the exact base. Do not run the same
aggregate before and after a commit solely to produce both dirty and clean
receipts. If a repair changes the candidate, rerun the nearest failed check
first and execute the aggregate once more for the repaired commit.

For repository CI, run feature-candidate validation from pull-request events
and retain `main` push readback. Cancel superseded same-head runs. Keep Quick
contexts required, and make a separate required Standard context execute only
its additional delta instead of replaying Quick.

Run static, schema, contract, fixture, and synthetic checks before platform or
device validation. Do not run a device suite to prove documentation or schema
changes. When device validation is actually required, route it through
`$meta-quest-workflow`.

Require validation evidence to bind exact criteria, artifacts, repository
revisions, ancestor bases, and in-scope changed paths. Revalidate before
acceptance so drift rejects. Keep acceptance under the workflow owner.

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
