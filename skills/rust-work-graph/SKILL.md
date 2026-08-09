---
name: rust-work-graph
description: 'Use for graph-based coding workspace analysis: repo inventories, source-root and framework maps, AGENTS.md and skill instruction audits, pattern registries, architecture/layer/domain graphs, dependency pressure, diff-impact planning, and graph-tool evaluation.'
---

# Rust Work Graph

Use this skill for graph-based coding workspace analysis: repo inventories,
source-root maps, language/framework maps, AGENTS or skill instruction-surface
audits, dependency pressure, architecture/layer/domain graphs, and broad
cleanup planning.

## Resolve The Local Work Environment

When installed by `Install-LocalSkills.ps1`, read
`references/local-work-environment.json` before following work-environment doc
paths. It binds the exact local clone, source commit/release, dirty-source state,
and docs root. If absent, use an explicitly configured
`RUSTY_MORPHOSPACE_WORK_ENVIRONMENT` or ask for the clone; never guess paths.

## Default Order

1. Start with the smallest inventory that answers the question.
2. Prefer `rg` and `rg --files` for text and file discovery.
3. For Git repos, prefer tracked-file inventories before full filesystem scans.
4. Add targeted pattern scans only after inventory shows a reason.
5. Do not scan generated outputs, SDKs, APKs, build folders, caches, or
   private artifacts unless they are explicitly the subject of the audit.

## Snapshot Content

A useful inventory records:

- repo root;
- Git branch and dirty state;
- language roots;
- build files;
- validation commands;
- instruction files;
- generated or ignored output roots;
- high-pressure files or modules;
- public/private boundary notes.

For branch/worktree lifecycle work, route the exact procedure through
`docs/REPOSITORY_LIFECYCLE.md` in the resolved Work Environment. Require the
strict consumer registry and read-only advisory before proposing retirement.
`candidate-retire` is only an owner-review edge: it never authorizes a delete,
local cleanup, merge, GC, ref update, or GitHub setting change. Preserve
`hold` and `incomplete` nodes with their exact consumer and reevaluation gate.
Keep remote ref retirement separate from local branch/worktree cleanup, and
resolve each repository's divergent, dirty, or tip-mismatched legacy refs
before graphing adoption of a new byte-level source policy.
For that adoption, inventory raw tracked blob bytes and classify exact paths as
canonical UTF-8/LF or byte-exact legacy/binary before changing attributes.
Treat `core.autocrlf`, editor presentation, and filtered hashes as observations,
not authority; route the exact policy and pre-signing check through
`docs/AUTONOMOUS_ITERATION.md`.

## Graph Interpretation

Graph evidence is a routing aid, not proof that a dependency belongs in core.
Use it to find:

- module ownership pressure;
- generic utilities trapped in app repos;
- instruction surfaces that are too broad;
- source files mixing independent authority;
- validation gaps.

Then route portable ownership and workflow questions through
`rusty-morphospace`, and authority design through `system-engineering`. Use
`rusty-morphospace-context` only when an explicit machine-local environment
must be resolved.

When a project uses the portable `morphospace/` workflow, compare graph
findings with the project spec and current iteration-unit scope. A graph can
identify pressure; it does not authorize edits outside the declared repos or
paths.

If work-unit automation emits a `graph_scope`, use its sorted repositories,
normalized allowed paths, and change categories as the maximum scan envelope.
Exclude unlisted repositories and paths; the scope is authority for bounded
discovery, not evidence that every listed path changed.

If `CorrectActiveReadOnlyDependencies` has transactionally changed an active
unit's read-only closure, treat only the resulting declared repositories and
paths as additional read-only scan edges. Preserve writable/read-only edge
distinction, bind each read-only edge to its corrected full commit/tree, and do
not infer that the action materialized or validated those repositories.

For concurrent multi-repo work, graph the exact source-composition lock as the
revision authority and live working-copy heads as observations. Keep claimed,
validated, and accepted revision edges distinct. Include materialization,
build-output, Android-package, property/staging-namespace, bridge-port, and
headset claims as resource edges; collisions are rejection edges rather than
implicit sharing.

Treat the project-local `morphospace/` directory itself as an instruction and
authority surface. Check that source edges into optional modules agree with the
closed feature lock, and report nearby-but-absent features as inert rather than
silently adding them to the project.

Graph an `<old>-superseded-by-<new>` transition as one directed authority edge:
event target independently names the active/validating old unit and target
state independently names the distinct new unit; the event ID is only their
exact unambiguous rendering. Attach the authenticated pre-state and exact
old-unit path/document hashes to the edge. A target-as-event identity, legacy
unbound intent, delimiter ambiguity, or endpoint drift is a rejection edge,
not a repairable alternate history.
When the workflow owner supplies an authenticated completed-transition
semantic correction, graph it as a separate evidence node binding the exact
historical event/prefix, retained old and replacement units, original
intent/completion, and correction intent/completion. Only that verified node
may relabel the historical edge's effective old endpoint; a path-only receipt,
damaged chain, nonempty original artifact vector, or ordinary malformed event
remains a rejection edge. Route the contract to
`docs/COMPLETED_TRANSITION_SEMANTIC_CORRECTION.md`.

For particle extraction graphs, report owner surfaces separately: Matter
simulation/contracts, Lattice relations, Optics appearance/projection, Quest
platform/render adapters, and application composition. Search those owners for
an existing contract before recommending a new module or schema.
The landed source map is anchored by Matter
`fixtures/particles/contract-conformance.json`, Lattice
`crates/rusty-lattice-model/src/anchor.rs`, and Optics
`crates/rusty-optics-fixtures/src/particle_contract.rs`; include their damaged
boundary fixtures in future impact graphs.
For Quest adoption, connect the adapter crate, both app consumer modules, the
two-consumer fixture, runtime profile, property manifest, and evidence checker
as one slice without assigning nearby renderer/private-particle code to adapter
ownership.

For the hand substrate, graph Lattice capability/frame/mapping, Matter
rig/joint-frame/CPU-skinning conformance, and Optics identity-preserving visual
profiles as three owner clusters. Include provider-mixup, basis-mismatch,
invalid-rig, and backend-leak fixtures as rejection edges.

For Quest adoption, connect the hand-adapter crate, native and Spatial
consumers, native hand-lab app build, property manifest, conformance and damage
fixtures, and device evidence reducer. Do not absorb neighboring OpenXR,
Spatial, or renderer modules into adapter ownership.

For sidecar workflow consolidation, graph the Termux source profile, the six
DAG phase nodes, registry/profile validator dispatch, all compatibility
artifact references, and damaged authority edges as separate clusters. Report
retained serial v1 tools as compatibility leaves, not new DAG stages.

For Manifold peer authority, graph identity/status proposals into one review
node, then branch to accepted state plus application receipt or rejection plus
unchanged revision. Include trust, replay, staleness, role escalation,
high-rate, and command-field fixtures as rejection edges.

For authenticated peer sessions, graph rendezvous evidence into Manifold
proposal/review, accepted decisions into revision-scoped topology
authorization, and rejected decisions into unchanged state. Connect explicit
revocation to the next revision and stale-receipt rejection. Keep BLE and
Android Wi-Fi P2P outside Manifold authority and gate every topology edge.

For N-peer meshes, keep observations/proposers outside the authority cluster,
then graph review into membership revision, coordinator epoch, route ranking,
selected direct pairs, expiry/revocation, and audit. Separate advisory from
authenticated direct-lane edges; add rejection edges for replay, stale state,
split brain, disconnection, revoked resurrection, and advisory-media
substitution. Attach live-device evidence only to live peer nodes.

For a release-candidate graph, include owner full checks, failed and passing
matrix summaries, workflow recovery, client rebind, provider fresh-epoch
rebuild, route cleanup, N-peer damage edges, private receipt references, and
instruction updates. Preserve failed-attempt nodes, and rerun/reconnect the
touched repo's full-check node after any source fix.

Treat the work-environment `0.1.0` release manifest and graph as a historical
checkpoint, not terminal proof. The July 11 strict audit found that the graph
omitted tracked Rust `src/bin` files and did not contain the terminal planning
transition. A corrected release graph must reconcile its file set against the
exact Git trees, include workflow state and validation surfaces, and label any
intentional third-party or generated exclusions. A later dirty filesystem scan
does not replace a versioned release node.

For historical release closure, graph the sealed capsule's exact commit trees
from isolated clean materializations. Treat current branches as ancestry and
no-rewrite observations, and current dirty worktrees as excluded overlays.
Branch convergence belongs to the candidate cut, not to permanent
post-release state. Keep damaged original evidence and any independent
reconstruction as distinct nodes.

Tracked-file inventories must include every deliberately committed executable
source, including Rust `src/bin`, and tracked dependency/license material.
Never treat a directory named `bin` as build output in tracked mode. Untracked
filesystem scans may skip build/dependency trees but must still retain
`src/bin`. Reconcile release counts to `git ls-tree`/`git ls-files` and make
remaining filters explicit. The canonical snapshot writes
`tracked-tree-reconciliation.json`: require its exact HEAD, included/excluded
counts, named exclusion reasons, missing-worktree paths, index-only paths, and
`reconciles=true` before using a graph as release evidence.

Every release graph carries an instruction-impact receipt that records whether
the nearest AGENTS/README/router and routed skills were updated or reviewed
without change; inferred graph edges never substitute for that receipt.

For generic media sessions, graph the accepted Manifold descriptor to the
platform runtime, then source → processor → route provider → sink, with codec
and socket authority as separate nodes. Include receiver-first transitions and
damage edges; remote-camera is compatibility ingress, not parallel authority.

For the Manifold Runtime Host, graph snapshot, command registry, lease set,
review, dispatch receipt, application receipt, explicit expiry, restart, replay
set, and audit chain as distinct authority nodes. Treat sockets, platform
adapters, product locks, and plugins as absent downstream nodes.

For broker products, graph product spec to feature descriptors to the exact
Manifold lock, then to the Quest Android manifest projection. Connect runtime
mode, commands, streams, modules, and permissions as one closure; represent
stale fingerprints, expanded fields, permission unions, and invalid mode count
as damaged rejection edges rather than alternative product paths.

For standalone/embedded authority adoption, branch the exact product lock into
placement-specific adapter configs and JNI/process edges, then converge both on
one Runtime Host review/application node. Compare applied, unknown, and
unleased host receipts as parity edges; graph local Java acceptance rules,
authority-label substitution, mode mismatch, and command-registry drift only as
rejection edges.

For Android RFC6455 consolidation, graph each standalone or embedded
HTTP/socket acceptor into one shared transport core. Put upgrade/framing,
bounded per-client message/byte queues, isolated writers, liveness/close,
cancellation, and sanitized telemetry inside that core. Keep JSON, Binder,
Manifold, command effects, and media as separate owner nodes or explicit
rejection edges, and require host differential parity before device edges.

For cross-app admission, graph Binder sending UID to package/signing-certificate
evidence, then to the Manifold client grant, token issue, one-time capability
use, revocation/expiry, revision, receipt, and audit nodes. Model different
signer, identity substitution, capability escalation, random-token collision,
replay, stale revision, expiry, and revoked-token reuse as distinct rejection
edges; keep WebSocket transport acknowledgements outside admission authority.
Add separate process, binding, session, broker-epoch, logical-operation,
attempt, correlation, registration, command, and owner-effect nodes. Connect
late callbacks/replies/deadlines to stale-generation rejection edges, exact
registration replay to one equivalence edge, and ambiguous relative effects to
an `outcome_unknown` terminal node rather than a retry edge.

For multi-app consumers, keep separate package/client/feature-lock/marker/
grant/sink clusters, converging only at the shared SDK and accepted peer/media
contract nodes. Add parity edges for shared contracts and rejection edges for
identity reuse, ambient union, cross-markers, copied defaults/properties,
unsorted capabilities, authority reset on rebind, and incomplete release.
Attach distinct app ids and per-client lifecycle/cleanup evidence to the
individual clusters rather than collapsing them into one broad client.

For a long-running authority stage, graph the quick contract, input capsule,
runner release, host probe, materialized clean room, readiness-only preflight,
fresh transaction/nonce, authoritative rerun, outputs, transition, and typed
failures separately. Add cache invalidation edges for input, dependency,
runner, materializer, host, fingerprint, policy, and owner drift. A later pass
may recover from but must not replace a failed attempt.

For direct-network graphs, keep topology providers, platform network
observation, socket providers, exchange protocols, and cleanup receipts as
distinct nodes. Model any harness-to-product dependency as a pressure or
rejection edge rather than reusable ownership.

Treat `AGENTS.md`, `SKILL.md`, README, and router docs as graphable instruction
surfaces. Module-layout or repo-routing changes must include their
synchronization records; keep detailed scan recipes outside the entrypoints.
Graph the external-owner gate only from the exact protected-without-approval
result through one pinned-owner signed authorization identity to the exact
static assessment; exact-evidence reruns remain idempotent within freshness,
changed evidence rejects, and trusted-base ancestry consumes the authorization;
execution, acceptance, and publication remain disconnected authority nodes.
For an ordinary typed two-parent source integration, graph the separately
attributed side/content commit, ordered side/protected parents and trees, merge
base, final tree, all four path projections, and the empty plain merge
projection. Never convert that exact proof into general empty-commit tolerance.
For non-ordinary executed prepared-publication evidence, graph the plan owner,
prepare transition, executed receipt, pending bundle, and live remote refs as
separate nodes. A merge integration must retain ordered side/protected parents,
their merge base and trees, and base-to-parent plus parent-to-final path-set
edges; never replace that graph with an empty single-commit projection.
For a signed prepared-push transaction-suffix reconciliation, graph the plan,
prepare event, five exact dirty paths, clean linear source refs, one planning
receipt-only suffix, owner authorization, and pending bundle as distinct nodes.
Permit only the bundle-consumption edge; do not infer Git, acceptance,
execution, or publication authority.

Graph historical-unit adoption as an additive evidence node linked to exact
unit bytes, terminal event, source workflow, and normalized semantics. It must
not create an authority edge for current work. Model retired `publication` to
`feature` only as a blocked-unit projection with hashed terminal evidence, not
as a publication edge. If it normalizes a blocked skill
surface action, retain the `planned` node and do not add completion or execution
edges.
If a terminal blocked unit wholly lacks a required skill node, add only the
exact current-validation projection edges from its bound unit, blocker event,
and terminal receipt to the required canonical skill nodes. Keep those nodes
`planned`; add no edit, completion, execution, or current-work authority edge.
Graph drift as separate expected-hash, observed-byte, and independently
reconstructed nodes; only the reconstruction may connect to current validation.
For embedded recovery, graph published source tree, exact external projection,
and later reconciliation without implying external planning existed at
publication time. Route the exact projection checks through
`docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md`.

Graph unpublished planning-authority materialization separately: one dirty
source checkout identity and one complete bounded repository-root
`morphospace/` inventory feed an
atomic stage/readback node in a distinct clean planning repository. The
destination becomes sole workspace authority; the untouched source becomes a
historical/non-authoritative leaf. Keep publication projections, workflow
admission, validation, acceptance, Git mutation, caller eligibility claims,
and sibling source paths as
disconnected or rejection edges.
Model Windows physical identity separately from path labels: volume serial plus
FileIdInfo connects namespace aliases to the same repository/common-dir node,
while identity change between observations is a rejection edge.
