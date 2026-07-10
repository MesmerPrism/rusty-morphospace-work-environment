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

Treat `AGENTS.md`, `SKILL.md`, README, and router docs as graphable instruction
surfaces. Module-layout or repo-routing changes must include their
synchronization records; keep detailed scan recipes outside the entrypoints.
