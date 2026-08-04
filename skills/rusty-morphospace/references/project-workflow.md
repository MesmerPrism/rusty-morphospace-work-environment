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

Separate source, build, and run identities. Use disjoint application,
client, marker, output, property, staging, and other mutable resource
identities. Treat machine-local claims as coordination only; they do not
activate features or authorize Git or device operations.

## Work-Unit Lifecycle

Allow at most one current active or validating unit. Keep inspection and
planning non-mutating; require explicit execution for an owned state
transition. Use the workflow owner's actions instead of hand-editing status,
compact state, or event history.

For an exact `<old>-superseded-by-<new>` event, require the ledger preflight to
bind pre-state `current_unit` and event `unit_id` to the active/validating old
unit, while target-state `current_unit`, the unit-path document, and target
unit bind the distinct new unit. Reject any mismatch before intent, artifact,
projection, or event mutation.

Derive repository, path, graph, and validation scope from the unit. Keep
proposals, claims, validation results, acceptance, publication planning, and
external execution as separate facts. A passing check is evidence, not
acceptance. A prepared publication plan is not execution evidence.

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
