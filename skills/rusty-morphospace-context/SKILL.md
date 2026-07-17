---
name: rusty-morphospace-context
description: 'Use for Rusty Morphospace repo-family orientation, lane ownership, public/private boundaries, project-workflow routing, local onboarding, native Quest defaults, legacy Makepad compatibility, and cross-repo instruction impact.'
---

# Rusty Morphospace Context

Use this skill to find the authoritative workspace state, choose the owning
repo lane, preserve public/private boundaries, and route work into the portable
project workflow. It is a router, not a copy of live project state.

## Resolve The Local Work Environment

When installed by `Install-LocalSkills.ps1`, first read
`references/local-work-environment.json`. It records the exact local clone,
source commit, release, dirty-source state, and docs root used for installation.

If that file is absent, use an explicitly configured
`RUSTY_MORPHOSPACE_WORK_ENVIRONMENT` or ask for the clone location. Do not guess
another contributor's paths and do not add absolute paths to this skill.

From the resolved work-environment root, read:

1. `README.md`
2. `AGENTS.md`
3. `docs/REPO_LANES.md`
4. `docs/PUBLIC_PRIVATE_BOUNDARY.md`
5. `docs/SETUP_OVERVIEW.md`

For a project with a `morphospace/` directory, then read its nearest
`AGENTS.md`, `morphospace/project.spec.json`, `feature.lock.json`,
`workspace.state.json`, current unit, and referenced receipt. A private planning
workspace may define a stricter first-read order; its compact state index, not
this skill, owns the current unit and release handoff.

## Companion Skills

- Use `system-engineering` for architecture, authority, contracts, adapters,
  observability, validation, and mitigation maps.
- Use `rust-work-graph` for broad repo inventories, source/dependency maps,
  instruction audits, diff impact, and graph receipts.
- Use `meta-quest-workflow` only for headset, ADB, APK, logcat, screenshots,
  Perfetto, Wi-Fi ADB, or Meta tooling work.

Live device work follows the public `meta-quest-agent-workflow` repository.
This router must not fork its device procedure.

## Lane Defaults

- Rusty Morphospace is the umbrella identity, not a default schema namespace or
  replacement for concrete owners.
- Matter owns computational matter, geometry, SDF, particles, sampling,
  dynamics, and deterministic CPU reference behavior.
- Lattice owns generic tracked-space relations, transforms, poses, view sets,
  validity, confidence, staleness, and capability snapshots.
- Optics owns renderer-neutral appearance, projection, visual contracts, and
  CPU-prepared visual payloads.
- Manifold owns command, session, stream, accepted peer state, host manifests,
  and control-transport authority. Manifold Packages owns product-specific
  packages that should not expand core authority.
- LSL owns independently authored LSL compatibility and typed observations or
  proposals; it does not replace Manifold stream authority.
- GUI owns portable interaction descriptors and command bindings, not hidden
  setup or runtime policy.
- Quest owns Android/OpenXR/Spatial SDK platform adapters, permissions,
  packaging, lifecycle, and effective runtime receipts.
- Hostess owns install/test/report workflows and Windows CLI/API-equivalent
  operator projections.
- Public Rusty XR remains a compatibility/reference lane; preserve its APIs
  unless an explicit migration is approved.
- Makepad repos are legacy compatibility, regression, historical-evidence, or
  migration lanes. New Quest work defaults to native OpenXR/Vulkan or Meta
  Spatial SDK; new Windows operator work defaults to WPF plus CLI/API parity.

Keep generic core slices contract-first and dependency-light. Android, OpenXR,
renderers, sockets, media SDKs, dynamic plugins, sidecars, and app policy stay
in adapters or app shells unless a reviewed owner contract says otherwise.

## Authority And Activation

One owner defines each runtime parameter; CLI, profiles, environment variables,
Android properties, UI, hotload, and commands adapt into that owner. Raw adapter
readback proves transport only. Acceptance requires effective consumer evidence.

Project composition is closed-world. `project.spec.json` owns the declared
composition, `feature.lock.json` owns the resolved permission/effect closure,
and runtime activation additionally requires a descriptor-approved current-run
input. Unlisted, denied, stale, or merely registered features remain inert.
Descriptor filesystem locations are local resolver inputs only. A v2 lock uses
forward-slash descriptor references relative to its `project.spec.json` and
rejects absolute, parent-traversing, or out-of-project paths.

When active working copies move in parallel, bind cross-repository work to a
clean exact source-composition lock and prefer its detached materialization.
Keep observed, claimed, validated, and accepted revisions distinct. Parallel
APK builds require disjoint package/client/output/property identities; runs on
one headset are serial-scoped transactions.

UI handlers collect inputs, invoke owned routes, show progress, and project
structured evidence. Every accepted operator action needs a CLI or local API
route with the same authority and evidence.

## Public And Private Boundary

Portable content uses placeholders and public repo names. Never commit local
absolute paths, private repo identities, device serials, package identities,
signing/pairing material, APKs, raw logs, screenshots, captures, credentials,
or private payload semantics.

Reference code is design pressure, not a source template. Extract vocabulary,
failure modes, interfaces, fixture shapes, and validation discipline only after
license/provenance review. Existing active/reference repos remain intact unless
the user explicitly authorizes a move, rename, cleanup, or rewrite.

## Project Workflow

For composition, module extraction, activation, iteration, or promotion, read:

1. `docs/PROJECT_WORKSPACE_PROTOCOL.md`
2. `docs/MODULE_LIFECYCLE.md`
3. `docs/FEATURE_ACTIVATION.md`
4. `docs/AUTONOMOUS_ITERATION.md`
5. `docs/PROJECT_ISOLATION.md`
6. `docs/INSTRUCTION_SYNCHRONIZATION.md`
7. `docs/RELEASE_CAPSULE_AND_HISTORICAL_CLOSURE.md` for a release cut,
   post-release audit, or damaged publication-evidence repair.

Work only in the repositories and paths declared by the current unit. Use the
owned automation for transitions; inspection is non-mutating and writes require
explicit execution. A validation pass is evidence, not acceptance. Preserve
blocked/interrupted history, dirty user work, exact repo heads, cleanup state,
and public/private evidence boundaries.

Treat a release as sealed commits and trees, not permanently frozen live
branches. Require exact remote equality and convergence at the candidate cut;
later historical closure requires ancestor-or-equal refs and isolated clean
materialization. Observe dirty active work without mutating it or absorbing it
into the release.

## Validation And Instruction Impact

Use Quick checks while iterating, Standard before a coherent handoff, and Deep
for broad graph, release, authority, or device-gated consolidation. Do not run a
device suite to prove docs or schemas.

When ownership, activation, validation, repo routing, device policy, or public
boundaries change, update or explicitly review the nearest `AGENTS.md`, README,
portable docs, and relevant skill routers in the same unit. Keep first-hop files
short and link detailed runbooks.

Do not encode a transient active unit, roadmap position, device identity, or
release candidate in this skill. Read those from the current project's compact
state and receipts every time.

Historical-unit normalization is project evidence, not runtime authority: only
exact hash-bound accepted or blocked units may use it; current units remain
closed against the published portable registries.
