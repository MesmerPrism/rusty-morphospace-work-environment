# Project Workspace Protocol

This protocol gives each Rusty Morphospace application a small, explicit
control surface for project composition, reusable-module extraction, and
autonomous iteration. The work-environment repository owns the portable
protocol and templates. Each application or planning repository owns its live
instance and evidence.

For a coordinated release, add a sealed `release_capsule.v1` under the
project-owned receipt/evidence surface and validate it at the candidate cut.
Later closure audits use ancestry, exact pinned trees, and isolated clean
materialization; they do not require current contributor worktrees to be clean.
See [Release Capsules And Historical Closure](RELEASE_CAPSULE_AND_HISTORICAL_CLOSURE.md).

## Decision

Create a `morphospace/` directory in each project that adopts this protocol.
The directory describes what the project is, which repositories an agent may
touch, which modules are available, which features are explicitly active, and
which iteration unit is current.

The project specification is composition authority. It is not runtime
authority for the modules it composes. A module's owning lane remains the
authority for its contract, and an app or platform adapter remains the
authority for app-shell or platform behavior.

New workspaces use protocol v2. Existing v1 workspaces remain readable and may
be migrated through an explicit unit; do not rewrite their event history.
`project_spec.v2` adds owner, selected/denied features and modules, permission
and data-class policy, acceptance profiles, and release/push policy.
`workspace_state.v2` adds exact repo heads, the last accepted receipt, and the
current module/capability registries. The optional repository checkpoints keep
observed, claimed, validated, and accepted revisions distinct.

## Directory Contract

```text
<project-root>/
  morphospace/
    project.spec.json
    feature.lock.json
    workspace.state.json
    iteration-events.jsonl
    features/
    module-candidates/
    module-extraction-receipts/
    iteration-units/
    promotion-reviews/
    receipts/
    source-compositions/
```

- `project.spec.json` declares purpose, repositories, module candidates,
  parameter authority, non-scope, and validation profiles.
- `feature.lock.json` is the closed-world feature composition lock. Unlisted
  or denied modules and features are inert. In v2 it includes descriptor and
  source hashes, the complete packaging/runtime effect union, and one lock
  fingerprint; composition still does not activate a run.
- `workspace.state.json` is the compact resume surface for an agent.
- `iteration-events.jsonl` is append-only chronological evidence.
- `features/` holds the owner-issued descriptors selected by this project.
- `module-candidates/` holds extraction records throughout their lifecycle.
- `module-extraction-receipts/` binds an extraction to exact source and target
  commits/trees and its app-specific exclusion boundary.
- `iteration-units/` holds independently reviewable work packets.
- `promotion-reviews/` holds gate decisions for module maturity changes.
- `receipts/` holds structured validation, non-executing push plans, and
  externally produced executed-push receipts. A plan never substitutes for
  exact remote readback.
- `source-compositions/` holds exact multi-repository commit/tree locks. Use a
  detached materialization when active working copies are changing in
  parallel.

Generated APKs, logs, screenshots, traces, pairing material, private payloads,
and tool caches do not belong in this directory.

## Project And Module Firewall

Application-specific details stay on the project side of the boundary:

- product names, package identities, launch activities, signing, permissions,
  and store metadata;
- scene composition, visual treatment, study rules, content, and tuning;
- private assets, endpoints, payloads, participant data, and release policy;
- app-specific defaults and recovery behavior.

A reusable module may cross the boundary only with:

- neutral vocabulary and an owning lane;
- a versioned contract or schema;
- explicit `owns` and `does_not_own` lists;
- platform-independent fixtures or a conformance harness;
- declared dependencies and parameter authority;
- provenance, license, public-boundary, and rollback records.

An originating application is evidence that a module is useful. It is not
proof that the module is general-purpose.

## Instruction Surfaces

An iteration unit declares whether it changes durable instructions. Changes to
authority, module layout, activation, validation, device policy, repo routing,
or public/private boundaries must update the nearest `AGENTS.md`, a README or
router doc, and relevant skills before acceptance. Implementation-only units
may declare no impact only with an explicit justification.

Use the matrix in
[Instruction Synchronization](INSTRUCTION_SYNCHRONIZATION.md). Entry points
remain compact routing indexes; detailed recipes belong in named docs and
runbooks.

## Authority Map

Every mutable runtime parameter has one master owner. The project spec names
that owner and may name adapters, but adapters do not become parallel sources
of truth.

Examples:

- Manifold owns command, session, stream, and lease decisions.
- Lattice owns generic tracked-space relations and validity.
- Quest app shells own Android permissions and effective platform profiles.
- Application shells own composition and private behavior.

Raw adapter readback proves transport. Acceptance requires an effective-value
or effective-marker receipt from the consuming runtime.

## Repository Scope

Every repository entry declares an ID, role, path, and allowed paths. An
iteration unit can narrow this scope, but cannot expand it. An autonomous agent
must stop if the required change falls outside both declarations.

Use repository-relative paths in committed project instances when possible.
Use placeholders in public templates. Never copy workstation paths into this
public repository.

## Bootstrap

Dry run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-ProjectWorkspace.ps1 `
  -ProjectRoot <project-root> `
  -ProjectId <project-id>
```

Create the directory:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-ProjectWorkspace.ps1 `
  -ProjectRoot <project-root> `
  -ProjectId <project-id> `
  -Execute
```

The scaffold refuses to overwrite an existing `morphospace/` directory.
It defaults to protocol v2; pass `-ProtocolVersion 1` only for an explicit
compatibility fixture.

Resolve a non-empty v2 lock from owner-issued descriptors:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Resolve-FeatureLock.ps1 `
  -ProjectSpecPath <project-root>\morphospace\project.spec.json `
  -DescriptorPaths <descriptor-paths> `
  -OutPath <project-root>\morphospace\feature.lock.json `
  -Execute
```

Descriptor input paths are filesystem adapters used only to read and hash the
files. Every descriptor must live under the directory containing
`project.spec.json`; the resolver writes a forward-slash relative reference
such as `features/example.json` into the lock and rejects absolute, parent-
traversing, or out-of-project descriptor paths.

## Agent Resume Order

1. Read the nearest `AGENTS.md` and repository instructions.
2. Read `morphospace/project.spec.json`.
3. Read `morphospace/feature.lock.json`.
4. Read `morphospace/workspace.state.json`.
5. Read the current iteration unit, if one is active.
6. Read only the event tail and receipts named by workspace state.
7. Read the current unit's instruction-impact surfaces.
8. Inspect Git status for every repository in the current unit before editing.

This keeps resume context small while preserving a durable audit trail.

The optional automation CLI described in
[Autonomous Iteration](AUTONOMOUS_ITERATION.md) can produce the same bounded
inspection, validation matrix, graph scope, and state transitions. Its local
repository map is an adapter into project-declared scope; it cannot expand
that scope.

For cross-project source locks, resource claims, content-addressed build
identity, and repeated runs on one headset, follow
[Project, Build, And Headset Isolation](PROJECT_ISOLATION.md).

## Validation

Validate the portable examples and a project instance with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot <project-root>\morphospace
```
