---
name: system-engineering
description: 'Use for architecture and system-engineering work across local repos: authority boundaries, contracts, manifests, modules and adapters, data/control/media planes, observability, validation scorecards, workflow design, durable project memory, and maintainable handoff surfaces.'
---

# System Engineering

An unchanged declared publication leg may use synchronized-readback accounting
only with four equal revisions, executed `readback-only`, zero commits, clean
bound identity/order, and an explicit no-acceptance claim. It never relaxes
changed-repository enumeration.

Use this skill for architecture and system-engineering work across Rusty
Morphospace repos: authority boundaries, contracts, manifests, module/plugin
boundaries, data/control/media planes, observability, validation scorecards,
reference-intake notes, and mitigation maps.

## Resolve The Local Work Environment

When installed by `Install-LocalSkills.ps1`, read
`references/local-work-environment.json` before following work-environment doc
paths. It binds the exact local clone, source commit/release, dirty-source state,
and docs root. If absent, use an explicitly configured
`RUSTY_MORPHOSPACE_WORK_ENVIRONMENT` or ask for the clone; never guess paths.

## Output Shape

For substantial architecture work, produce:

- Decision
- Scope
- Non-scope
- Authority
- Interfaces
- Observability
- Validation
- Reference Lessons
- Mitigation Map
- Next Slice

Keep the output proportional. A small code/docs change may need only a short
decision and validation note.

## Authority Rules

- One master layer owns each runtime parameter. Other entrypoints adapt into
  that layer.
- Raw adapter readback proves transport only. Acceptance needs the consuming
  runtime to report the effective value or marker.
- Low-rate profiles, Android properties, hotload files, and command payloads
  are control surfaces. Do not move high-rate camera, depth, mesh, particle,
  pose, or GPU-buffer streams into them.
- UI handlers collect parameters, invoke routes, show progress, and project
  structured evidence. They should not own hidden setup or business logic.
- Project composition uses a closed-world feature lock. In protocol v2 an
  owner-issued descriptor is pinned by descriptor/source revision and hash;
  the resolver records a project-spec-relative descriptor reference and the
  exact packaging/runtime effect union. Resolver filesystem locations are
  adapter state and never lock content. Unlisted or denied modules are inert,
  and selection alone cannot activate a run.
- Stable reusable modules require a second independent consumer or neutral
  conformance harness and an accepted promotion review.
- Raw evidence bytes precede text convenience. Enroll canonical text paths
  explicitly as UTF-8 without BOM and LF-only, preserve historical/binary paths
  byte-for-byte until a separately reviewed conversion, and reject CRLF, mixed,
  BOM, invalid-UTF-8, or binary evidence before hashing or signing. Never treat
  `core.autocrlf` or hidden normalization as authority.

## Portable Project Contracts

When a project has a `morphospace/` directory, treat `project.spec.json` as
composition authority, `feature.lock.json` as the permitted feature/effect
closure, and `workspace.state.json` as the compact agent-resume surface. In
v2 runtime activation additionally requires the current lock fingerprint and
one descriptor-approved runtime input; the consuming runtime receipt binds
project, feature, lock revision/fingerprint, and applied or rejected state.
Work only within the repository and path scope declared by the current unit.

For concurrent projects, separate the source, build, and run authorities. Bind
cross-repository work to exact clean commits/trees and use detached
materializations when live checkouts are moving. Give every APK an app-specific
package/client/marker identity and content-addressed output. Serialize runs per
headset serial, snapshot the complete declared property set, and restore exact
prior values in `finally` while stopping only the target package.

Reusable extraction requires a hashed receipt binding source composition,
source/target commits and paths, the neutral contract, dependency audit,
disabled default, private-payload absence, and app-specific exclusions. The
originating app remains evidence, not module authority.

Use one fail-closed owner for unit state transitions. Inspection and planning
are non-mutating; execution is explicit. Derive validation and graph scope
from the unit, keep acceptance separate from a pass receipt, preserve blockers
through resume/recovery, and report dirty, detached, ahead/behind, or divergent
Git states without rewriting them. Push preparation records exact source-first,
planning-last revisions but does not commit, push, or force-push.
Select the unit's guard authority separately from validation depth: `fast` for
bounded product iteration across declared repositories and device stages,
`labs` for composition and product-authority work, and `locked` for releases or
workflow trust-root changes. `risk_tier` governs evidence, not permission. For an
in-scope feature failure, `ReturnToActive` must validate and retain the
non-passing receipt while keeping the same current-unit owner; blocker plus
`Resume` remains the stop-and-release route.
Budget CI by exact candidate identity: validate feature work from pull requests,
retain post-merge `main` readback, cancel only superseded same-head runs, and
keep required tier contexts disjoint so Standard executes its delta rather than
replaying required Quick coverage. Route action-pin or workflow changes through
the locked validation-authority boundary.
For a writable path or repository discovered inside the same active feature
authority, use the additive `AmendActiveWriteScope` contract. It must bind
exact current project/state/unit/event identities, prove the complete
before/after set stays within project authority, mutex-bind the unchanged
project document, retain captain/status, and separate authorization from any
source, Git, build, validation, device, or remote execution.
Before expensive execution, prefer a hash-bound, project-produced
`execution_preflight_observation.v1` for exact package/application, signer,
grant, toolchain, source-lock, or bridge/port facts. The workflow may compare
declared values and capabilities but must not generate the observation or
mistake admission evidence for validation.
An additive `<old>-superseded-by-<new>` edge must derive old from the event
target and new from target state, then require the event ID to be their exact,
unambiguous rendering. Publish only a v2 intent that hash-binds the original
state and retained active/validating old-unit path/document. Completion fails
closed on legacy or damaged binding before applied-target recovery, repair, or
projection mutation.
For the one already-completed legacy-v1 event that has an exact rendered edge
but recorded the replacement as event unit, use only the derived
`completed_transition_semantic_correction.v1` owner receipt. Treat the
historical prefix, empty receipt/artifact shape, old/replacement unit bytes,
and both completion-to-intent chains as required authority. The additive
correction may change only `last_event_id` and append/install one exact
event/receipt; it does not weaken normal v2 transition semantics. Route detail
to `docs/COMPLETED_TRANSITION_SEMANTIC_CORRECTION.md`.
An exact still-unexecuted prepared bundle may be retired only after complete
stable clean observations, fresh remote readback, and exclusion of recognized
execution/publication evidence. If all distinct prepared revisions are already
reachable, use the separate complete-history reconstruction route instead.
Generic blocker resolution and its additive evidence correction bind exact
source bytes, attached-branch or exact detached heads, event/receipt/ledger
history, and state/event-tail CAS. Bound replay discovery to direct workflow
receipts and event-named receipt paths; nested product evidence is not generic
workflow authority. These routes preserve every unrelated workflow projection
and never perform external cleanup or Git mutation.
An early planning checkpoint with every source still unpublished may be bound
only through a publication-ordering interruption receipt in a fresh plan; exact
live ancestry must match and the plan claims no corrected order or publication.
The proposed-to-ready review is also an owned transition: use `Ready` to verify
accepted prerequisites, preserve the unit envelope, append the event, and
derive the claimable queue instead of hand-editing status/state/history.
For the matching active or validating unit, complete declared instruction surfaces only with the
two-phase `CompleteInstructionSurfaces` transaction: replay the exact unit
hash, stable surface-observation hash, and complete planned-surface ID set.
Treat its receipt as content-observation evidence, not execution evidence; it
  must change no other unit field and must not execute validation commands.
For an active unit whose admitted build/parser closure needs corrected
read-only identities, use the typed `CorrectActiveReadOnlyDependencies`
transaction instead of editing workflow JSON. Require exact state/unit/event
CAS, complete before/after sets, project-declared non-writable paths, and full
commit/tree identity resolution. Keep worktree materialization, build execution,
validation, acceptance, and publication outside that correction transaction.
`RecordValidation` and `Accept` must validate a workspace-local
`validation_receipt.v1`: exact acceptance/gate coverage, artifact hashes,
current heads/branches, ancestor bases, exact in-scope changed paths, and—when
device-gated—explicit serials, cleanup, and zero bounded package/system fatals.
Revalidate at acceptance so post-validation drift rejects.
For long-running promotion or validation-authority work, run a fail-fast
preflight in the exact execution environment first. Bind it to immutable
inputs, runner/tool release, host capabilities, materialized-workspace
fingerprint, owner probe, action, and attempt, and label it non-promotional.
The authoritative stage reruns under a fresh transaction identity and preserves
a typed bounded result before cleanup. Reuse a content-addressed checkpoint
only after exact input/materialization identity and fresh host/fingerprint
validation; drift invalidates it.
Declared partial-commit, interrupted-build, or interrupted-device recovery
requires a hashed `interruption_receipt.v1` with observed repo checkpoints and
kind-specific safe cleanup. Workflow recovery may restore state only; it never
owns Git, process, package, route, or device cleanup.
Normal claims reject dirty in-scope paths. Work started before protocol v2 may
cross that boundary only through a generated `inflight_adoption_receipt.v1`
that binds exact heads, paths, file/deletion state, and content hashes; any
post-receipt drift rejects.
After an externally authorized push, accept only a validated
`rusty.morphospace.workflow.executed_push_receipt.v1` with full old, new, and
observed remote revisions, ancestry and validation references, no-force proof,
planning last, and reverse-order rollback anchors. A prepared plan is never
execution evidence, and the work-unit automation must not manufacture this
receipt.
For a branch-scoped pre-push guard, identify the protected update from Git's
remote destination ref and resolve an explicit local selector such as `HEAD`
to the exact attached protected branch revision before plan validation.
Deletion, detachment, branch/SHA mismatch, malformed input, and duplicate
protected updates reject.
Close that prepared publication only through hash-bound
`planned_publication_accounting.v1`: enumerate exact commits and unit status,
restrict the one planning suffix to explicit workflow transport paths, and let
`RecordPublication` clear only the matching bundle after live clean readback.
Model a normal two-parent source integration as typed topology, not an empty
ordinary commit: retain the separately enumerated side/content attribution and
bind ordered parents/trees, merge base, all four path projections, and the
empty plain merge projection. Reject linear, untyped, or drifted empty entries.
If immutable execution predates its recorded plan timestamp and an exact source
final is a merge integration, use a distinct non-ordinary reconciliation:
bind both evidence containers, exact live refs, full path-set fingerprints,
ordered parents, merge base, and all per-parent projections. Preserve the
chronology defect and merge graph; do not weaken ordinary accounting.
Model a prepared-push transaction-suffix recovery as one signed, exact-bundle
state transition only when source owners are clean linear commits, planning has
one receipt-only commit, and exactly five transaction-owned paths remain dirty.
Bind every existing byte and timestamp; add no Git, acceptance, execution, or
publication-authority edge.
If that planning-only suffix was later replaced with force-with-lease, use the
additive incident contract binding exactly two common parent-relative paths,
one replacement delta path, both trees, and unchanged source refs; do not
relabel the original no-force execution or weaken ordinary accounting.
The live planning checkout may carry only the exact bound executed-push and
accounting receipts as a clean local prerequisite suffix while its remote stays
at the executed final revision; reject source ahead state, remote drift, dirt,
divergence, stale bindings, and every unrelated suffix path.
If that exact prerequisite suffix is already published, reconcile it only
through a separate hash-bound contract: v1 allows one no-force planning commit;
v2 allows exactly two linear full-ID commits when the second corrects only the
accounting receipt. Both forms allow exactly the two receipt paths, exact
executed-parent/current readback, unchanged clean sources, and one pending-
bundle consumption. This does not widen
`RecordPublication` or admit alternate history and rewrites.
An immutable executed bundle followed by a separately accepted workflow
correction may close only through intervening-accepted-publication recovery:
bind execution-time/current finals, exact fast-forward commits and paths,
accepted/pass evidence, narrow planning evidence roles, and source-first /
planning-last chronology. Never infer mutation from the old readback-only leg
or treat the recovery as generic remote drift.
Only this recovered shape may use an accounting-only local prerequisite when
the bound executed path/hash occurs exactly once in enumerated intervening
planning evidence; ordinary accounting still requires both evidence paths.
When the plan or event is embedded in owner evidence, bind the immutable
container and named member plus transition intent/completion linkage; do not
reconstruct a standalone artifact and claim equivalent provenance.
Keep mutable project state in one distinct external planning repository and
require its ref as the final prepared suffix. If a real source push preceded
preparation, preserve it only through an independently observed
`unplanned_publication_closure.v1`; `ReconcilePublication` may repair the
planning projection but cannot create a retrospective plan, executed receipt,
Git mutation, or source-authority claim.
When the workspace was embedded in that published source, bind its exact
published-tree bytes into distinct external planning through
`planning_workspace_projection.v1` and require
`unplanned_publication_closure.v2`. Reconciliation mutates only that external
projection. Route the exact byte/inventory procedure through
`docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md`.

For the separate unpublished-only case, use
`MaterializeUnpublishedPlanningAuthority` only for repository-root
`morphospace/` with exact `workspace.state.json`, when Git reports that path
dirty and its complete bounded live inventory differs from the pinned source
tree. That derived predicate excludes projection v1-v3; never accept caller
prose or claims as eligibility. Bind the source HEAD/tree/branch, complete
ordinal inventory and fixed anchor, re-observe before the atomic destination
commit point, preserve the source as historical/non-authoritative, and require
ordinary later admission. Never widen projection v1-v3 or copy sibling source
or runtime files.
On Windows, bind repository roots, Git common directories, existing destination
ancestors, stage, and installed destination by volume serial plus FileIdInfo;
replay those identities at staging, commit-point, and readback boundaries.

Separate release-candidate cut from historical closure. Seal exact commits and
trees while declared refs are equal; later require ancestor-or-equal refs and
verify those trees in isolated clean materializations. Active worktree dirt is
observed context, not historical payload. If accepted evidence bytes are
missing or hash-mismatched, preserve the damage and append an independent
reconstruction that explicitly does not claim to be the original.

For an adopting application, require a behavior-neutral bootstrap: select its
baseline shell, record optional nearby families as disabled, assert one
unrelated feature is absent and inert, and create candidate records before
extracting reusable source.

Candidate classification starts with owner-contract reuse. If Matter already
provides particle state, configuration, diagnostics, render-neutral payloads,
and surface-runtime snapshots, prove conformance and adapter isolation before
adding another schema; keep relations, appearance, platform rendering, and app
policy in their separate lanes.
The landed proof uses strict serialized fixtures: Matter binds its existing
state/config/diagnostics/render/surface-snapshot contracts, Lattice adds only a
situated pose relation, and Optics adds only a visual frame preserving Matter
identity. Unknown-field rejection is acceptance evidence that product,
platform, backend, private-driver, and cadence policy did not enter core.
The Quest proof uses one adapter crate and two thin consumer modules. The
adapter may prepare renderer-neutral instance rows; selection, backend
resources, markers, and app policy stay with each consumer. Require a disabled
zero-row receipt as rollback evidence.

For hand systems, preserve provider identity and coordinate basis end to end.
Lattice validates capability-to-frame ownership, Matter rejects provider,
handedness, reference-space, joint-count, weight, and rig mismatches before CPU
skinning, and Optics preserves provider/frame/rig/hand identity without backend
fields. Provider substitution must fail closed.

A Quest hand adapter must map provider joints to Matter target joints exactly
once, reject duplicate or incomplete targets, and compare its prepared rows to
the Matter CPU oracle. App consumers stay thin and default inert.

When serial expectation/preflight/handoff artifacts accumulate, consolidate
their relationships into a bounded DAG with named policy profiles and
registry-driven validators. Preserve compatibility artifacts, keep the DAG
non-executing, and assign approval/submission/decision/receipt authority to
their real owners instead of the workflow index.

For peer status, separate proposal, review decision, accepted state, rejection,
audit, and application receipt. Bind trust and replay checks to the review,
advance the authority revision only during accepted application, and reject
high-rate/media planes or advisory command fields before state mutation.

For rendezvous-to-topology flows, keep transport evidence, peer-session
decision, topology authorization, and platform mutation as separate
authorities. Bind short-lived authorization to the current revision, exact
peer roles, and topology contract. Rejection leaves state unchanged;
revocation advances it and invalidates older receipts.

For media runtimes, separate accepted session/stream references from platform
adoption. Compose source, processor, route, socket provider, codec, sink, and
terminal cleanup as explicit owners. Require receiver-first revisioned
transitions and sink-observed frames; compatibility adapters preserve behavior
without exporting legacy defaults or permissions.

Keep command acceptance, prepared platform action, every required owner
completion, Rust application, and independently observed effect as distinct
facts. A successful dispatch remains incomplete until exact current-epoch
owner receipts, including terminal cleanup where selected, have applied.
Treat a caller-supplied aggregate `completed=true` document as an untrusted
proposal. Each selected owner adapter must issue its own receipt bound to the
provider instance/epoch, exact resource/action, prerequisite order, and an
owner-observed handle, counter, state, or readback before aggregation.

Keep trust roots and accepted operator/key/adapter sets in immutable or
revisioned authority state, never in mutation-call arguments. A canonical
descriptor, lock, or digest proves shape/identity only; downstream leases and
effects bind a retained current decision/receipt, revision, epoch, and digest.

A runtime authority host should separate review from application, bind every
dispatch receipt to the request and reviewed revision, advance accepted state
exactly once, and persist replay/audit lineage across restart. Expiry is an
explicit revisioned application, not a hidden timer mutation.

Resolve deployable products from a declared spec into an immutable exact lock:
runtime mode, features, commands, streams, modules, and permissions must close
together. A downstream packager may project that closure but must not union in
ambient capabilities. Reject stale fingerprints, expanded fields, duplicate
features, and zero-or-two runtime modes; keep sensitive features as separate
opt-ins rather than broadening the base product.

Treat standalone and embedded as placement adapters over one authority engine.
Bind both to the exact product lock and command registry, compare their
underlying decision/application receipts differentially, and label the process
or JNI layer as an adapter. A bridge may validate schema and authority labels,
but acceptance, lease, revision, replay, rejection, and next-state rules stay
in the shared authority owner.

Treat standalone and embedded RFC6455 servers as placement adapters over one
transport core. Put strict upgrade/framing, bounded per-client message and byte
queues, one writer per socket, Ping/Pong/Close deadlines, deterministic
cancellation, cleanup-exactly-once, and sanitized telemetry in that core. Keep
JSON semantics, Binder identity, Manifold decisions, command outcomes/effects,
and media outside it. Prove malformed-input, slow-client, shutdown/restart, and
placement parity on the host before any Binder or device phase.

For locked-playlist Hub integration on a moving public owner main, preserve
adopted product bytes by exact hash and materialize the pinned Manifold owner at
Cargo's manifest-relative sibling as a non-writable dependency. Require native
Connection Hub Cargo, shared WebSocket, Binder reducer, and broker-authority host
gates before owner publication; admit device evidence only from clean landed
owner bases in a separate unit.

Treat UI and ADB operator surfaces as adapters into one product authority. Gate
the published ADB adapter with the platform shell identity; expose only fixed
typed actions; reject caller-selected components, identities, grants, and
capabilities. Keep credentials out of receipts and require sent, pending, then
effective-state-confirmed, rejected, or `outcome_unknown` closure.

Schema ownership follows the payload. Preserve an owner-issued artifact
byte-for-byte and bind its exact path, schema, owner, and SHA-256 from a
separately named workflow wrapper. Never add workflow fields while retaining
the owner's schema ID or relabel an augmented wrapper as the owner receipt.

For cross-process admission, separate platform identity evidence from the grant
decision. Bind an OS-derived subject and signing identity to explicit
capabilities, issue high-entropy short-lived opaque tokens from the authority,
consume one-time request ids, and revision/audit issue, use, revoke, and expiry.
Test identity substitution, capability escalation, token collision, replay,
staleness, expiry, and post-revocation use; a transport ACK is never admission.
Drive Binder/Messenger lifecycle through one serialized reducer. Fence process,
binding, and session generations plus broker epoch; distinguish logical
operation, attempt, correlation, registration, command, and effect identities;
use bounded monotonic deadlines and cleanup exactly once. Retry only read-only
or byte-equivalent idempotent work. Reconcile desired state, and report unknown
outcome instead of replaying an ambiguous relative effect.

For a shared SDK used by multiple applications, validate the pair as well as
each client. Share only versioned contract families and the minimum transport
permission; keep OS/package identity, client id, feature lock, marker, grant,
and app-specific capability distinct. Reject ambient unions, duplicated
markers, copied defaults/properties, non-canonical capability sets, and
initialization that resets live authority. Device proof should exercise both
consumers against one authority and verify identity, revision continuity,
release paths, zero fatals, and cleanup.

For an N-peer control mesh, separate accepted membership from observations and
advisory connectivity from authenticated direct lanes. Require canonical
bounded membership, one deterministic coordinator per epoch, revision/replay,
expiry, revocation, audit, and stable direct-route ranking. Same-epoch
coordinator disagreement is split brain. Advisory edges may connect the
low-rate graph but cannot become direct/media authority without independent
authentication.

Release reliability separates workflow interruption, repository-state damage,
client death/rebind, and provider death. A client relaunch gets a fresh request
namespace and the current authority revision; provider death requires an
explicit fresh-epoch rebuild. Preserve failed attempts, rerun the touched
owner's full check after fixes, recheck replay/revocation/identity gates, and
require route inactivity, package cleanup, zero bounded fatals, and named
remaining limitations.

Treat work-environment `0.1.0` as the first versioned workflow baseline.
Schema or state-machine evolution must be additive or ship an explicit
migration, compatibility window, rollback, and accepted-history preservation
rule.

Do not make an event parser broadly tolerant to repair historical JSONL
framing. Exactly one leading CRLF blank record may be removed only through the
typed `NormalizeEventLedgerPrefix` owner migration: raw-byte and state/unit/
project/tail CAS, caller-pinned dry-run intent SHA-256, durable intent/
completion, receipt-after-target publication, unchanged prior event and
current-unit bytes, one appended correction event, and only `last_event_id`
changed. Every other blank record remains fail-closed. Route the detailed
procedure to `docs/EVENT_LEDGER_PREFIX_NORMALIZATION.md`.

When a terminal historical unit uses retired workflow vocabulary, require a
project-owned receipt binding exact bytes, status, terminal evidence, and
complete normalization into current portable semantics. Never use that route
for current work or expand registries merely to silence history. A historical
`publication` work mode may map only to `feature` for a blocked unit with exact
terminal event and receipt hashes; it is not publication evidence. A historical
instruction mismatch additionally binds the exact legacy impact and every
affected agent, router, or skill surface path/action. Preserve a blocked
surface's `planned` status and record no completion or execution claim; this is
not an ambient instruction-sync bypass.
When a required skill surface is wholly absent from terminal blocked unit
bytes, allow only an exact hash-bound projection of the currently required
skill IDs at canonical paths. Retain `planned`; reject optional, current,
accepted, completed, executed, or already-present surfaces.

A drifted historical-adoption receipt keeps its expected and observed hashes
as damaged original evidence. An immutable-Git-anchored
`historical_unit_adoption_reconstruction.v1` may affect current validation
only; it cannot restore the original receipt or acceptance chronology.

For direct networking, separate topology formation, platform network
observation, socket ownership, protocol exchange, and cleanup into provider
receipts. Platform absence is evidence, not permission to fabricate
authority; a socket provider may proceed only when its own route and bind
contract explicitly allows that fallback.

Authority, module-layout, activation, and validation changes also have
instruction impact. Route them through
`docs/INSTRUCTION_SYNCHRONIZATION.md`; update concise routers and place long
procedures in linked docs.

## Reference Intake

When borrowing from a reference, record:

- reference name or public URL;
- why it matters;
- lesson borrowed;
- overreach rejected;
- target Rusty layer;
- validation or follow-up.

Prefer schema-only and data-only contracts before runtime dependencies.

## Validation

Validation should prove the authority boundary, not just happy-path execution.
For Quest/APK work, source/static/profile gates come before headset runs. For
public extraction, synthetic tests or fixtures come before live evidence.

For a change to the validator, policy, workflow, or schema that would otherwise
approve itself, separate exact base-owned static admission from
credential-free dynamic execution. Route the portable two-PR contract through
`docs/EXTERNAL_VALIDATION_AUTHORITY.md`; its static assessment must retain
`candidate_code_executed=false`, `execution_attested=false`, and
`publication_authority=false`.
Its durable external-owner fallback admits only the exact v1
protected-without-base-approval result and binds one RSA-PSS authorization
to complete PR, Git, artifact, and assessment evidence. It authorizes only the
base static assessment, never execution, acceptance, or publication.
Its unique ID is audit identity: exact-evidence reruns are idempotent within
freshness, different evidence rejects, and trusted-base ancestry consumes it.
