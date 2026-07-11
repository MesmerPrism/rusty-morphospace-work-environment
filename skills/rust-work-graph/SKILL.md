---
name: rust-work-graph
description: 'Use for graph-based coding workspace analysis: repo inventories, source-root and framework maps, AGENTS.md and skill instruction audits, pattern registries, architecture/layer/domain graphs, dependency pressure, diff-impact planning, and graph-tool evaluation.'
---

# Rust Work Graph

Use this skill for graph-based coding workspace analysis: repo inventories,
source-root maps, language/framework maps, AGENTS or skill instruction-surface
audits, dependency pressure, architecture/layer/domain graphs, and broad
cleanup planning.

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

## Graph Interpretation

Graph evidence is a routing aid, not proof that a dependency belongs in core.
Use it to find:

- module ownership pressure;
- generic utilities trapped in app repos;
- instruction surfaces that are too broad;
- source files mixing independent authority;
- validation gaps.

Then route changes through `rusty-morphospace-context` and
`system-engineering`.

When a project uses the portable `morphospace/` workflow, compare graph
findings with the project spec and current iteration-unit scope. A graph can
identify pressure; it does not authorize edits outside the declared repos or
paths.

Treat the project-local `morphospace/` directory itself as an instruction and
authority surface. Check that source edges into optional modules agree with the
closed feature lock, and report nearby-but-absent features as inert rather than
silently adding them to the project.

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

For cross-app admission, graph Binder sending UID to package/signing-certificate
evidence, then to the Manifold client grant, token issue, one-time capability
use, revocation/expiry, revision, receipt, and audit nodes. Model different
signer, identity substitution, capability escalation, random-token collision,
replay, stale revision, expiry, and revoked-token reuse as distinct rejection
edges; keep WebSocket transport acknowledgements outside admission authority.

Treat `AGENTS.md`, `SKILL.md`, README, and router docs as graphable instruction
surfaces. Module-layout or repo-routing changes must include their
synchronization records; keep detailed scan recipes outside the entrypoints.
