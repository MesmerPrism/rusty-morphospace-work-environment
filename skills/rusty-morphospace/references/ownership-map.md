# Rusty Morphospace Ownership Map

Use this reference to place architecture, contracts, modules, adapters, and
agent work in the narrowest owning lane.

## Ecosystem Rule

Treat Rusty Morphospace as the umbrella identity, not a default schema
namespace or a replacement for concrete owners. Start reusable core slices
contract-first and dependency-light. Keep platform APIs, render backends,
sockets, media SDKs, dynamic plugins, sidecars, and application policy in
adapters or app shells unless an accepted owner contract places them elsewhere.

## Ownership Lanes

- Matter owns computational matter, geometry, signed-distance fields,
  particles, sampling, dynamics, and deterministic CPU reference behavior.
- Lattice owns generic tracked-space relations, transforms, poses, view sets,
  validity, confidence, staleness, and capability snapshots.
- Optics owns renderer-neutral appearance, projection, visual contracts, and
  CPU-prepared visual payloads.
- Manifold owns command, session, stream, accepted peer state, host manifests,
  leases, replay and revocation decisions, and control-transport authority.
  Product packages must not broaden Manifold core authority.
- LSL owns independently authored compatibility and typed observations or
  proposals; it does not replace Manifold stream or decision authority.
- GUI owns portable interaction descriptors and command bindings, not hidden
  setup or runtime policy.
- Quest owns Android/OpenXR platform adapters, including co-resident bridges
  and API-layer packaging, activation, interception, permissions, lifecycle,
  and effective platform receipts. Application shells retain their package
  identity, OpenXR/frame-loop ownership where applicable, semantic actions,
  composition, private behavior, and renderer choices. Manifold retains
  accepted-command, lease, replay, revocation, and control-transport authority.
- Hostess owns install, test, and report workflows plus equivalent Windows
  operator CLI or local-API projections.
- Compatibility lanes preserve existing public contracts until an explicit
  migration is approved; historical or reference code is design pressure, not
  automatic source authority.

## Authority Placement

Assign each mutable parameter one owner. Treat profiles, properties,
environment variables, UI controls, hotload files, and commands as adapters
into that owner. Transport readback proves only that an adapter moved data;
acceptance needs effective evidence from the consuming runtime.

Keep low-rate control data separate from high-rate media, camera, depth, mesh,
particle, pose, and GPU-buffer planes. Keep UI handlers limited to collecting
inputs, invoking owned routes, showing progress, and projecting structured
evidence.

Separate authority surfaces that are easy to conflate:

- composition from runtime activation;
- accepted control decisions from platform effects;
- topology formation from platform network observation and socket ownership;
- session or stream references from source, processor, route, codec, and sink;
- reusable module contracts from application defaults and permissions;
- validation evidence from acceptance;
- local coordination claims from feature, Git, or device authority.

Promote a reusable module only after an independent consumer or neutral
conformance harness and an accepted review. Bind extraction to exact source
and target revisions, paths, neutral contracts, dependency review, disabled
defaults, rollback, provenance, and private-payload absence.

## Agent Routing

- Use `$rusty-morphospace` for portable lane selection, composition, lifecycle,
  boundary, and validation routing.
- Use `$system-engineering` for designing or reviewing authority, contracts,
  interfaces, observability, validation scorecards, and mitigation maps.
- Use `$rust-work-graph` for bounded tracked-file inventories, source maps,
  dependency pressure, instruction audits, and broad refactor impact.
- Use `$meta-quest-workflow` before live Quest or device operations. Keep
  platform recipes and private evidence in that owning workflow.

An agent route narrows responsibility; it never expands repository scope or
grants Git publication, release, credential, or device authority.
