---
name: system-engineering
description: 'Use for architecture and system-engineering work across local repos: authority boundaries, contracts, manifests, modules and adapters, data/control/media planes, observability, validation scorecards, workflow design, durable project memory, and maintainable handoff surfaces.'
---

# System Engineering

Use this skill for architecture and system-engineering work across Rusty
Morphospace repos: authority boundaries, contracts, manifests, module/plugin
boundaries, data/control/media planes, observability, validation scorecards,
reference-intake notes, and mitigation maps.

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
- Project composition uses a closed-world feature lock. Unlisted or disabled
  modules are inert and cannot change unrelated packaging or runtime behavior.
- Stable reusable modules require a second independent consumer or neutral
  conformance harness and an accepted promotion review.

## Portable Project Contracts

When a project has a `morphospace/` directory, treat `project.spec.json` as
composition authority, `feature.lock.json` as activation authority, and
`workspace.state.json` as the compact agent-resume surface. Work only within
the repository and path scope declared by the current iteration unit.

Use one fail-closed owner for unit state transitions. Inspection and planning
are non-mutating; execution is explicit. Derive validation and graph scope
from the unit, keep acceptance separate from a pass receipt, preserve blockers
through resume/recovery, and report dirty, detached, ahead/behind, or divergent
Git states without rewriting them. Push preparation records exact source-first,
planning-last revisions but does not commit, push, or force-push.

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
adoption. Compose source, processor, route, codec, socket provider, and sink as
explicit owners. Require receiver-first revisioned transitions and sink-
observed frames; compatibility adapters preserve behavior without exporting
legacy defaults or permissions.

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

For cross-process admission, separate platform identity evidence from the grant
decision. Bind an OS-derived subject and signing identity to explicit
capabilities, issue high-entropy short-lived opaque tokens from the authority,
consume one-time request ids, and revision/audit issue, use, revoke, and expiry.
Test identity substitution, capability escalation, token collision, replay,
staleness, expiry, and post-revocation use; a transport ACK is never admission.

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
