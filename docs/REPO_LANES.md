# Repo Lanes

Rusty Morphospace is the umbrella. Concrete ownership stays in lanes.

## Core Lanes

| Lane | Owns | Does not own |
| --- | --- | --- |
| Matter | data, fields, forms, SDF/volume contracts, simulation-facing geometry | Quest lifecycle, Makepad widgets, package install |
| Lattice | spaces, transforms, tracked poses, view sets, spatial input roles, validity, confidence, runtime capability snapshots | renderer backends, Android property writes |
| Manifold | commands, sessions, streams, host manifests, control transport, schema routes | OpenXR tracking ownership, app package identities |
| Rusty LSL | independently authored LSL APIs/runtime compatibility, fixtures, oracle evidence, typed Morphospace observations/proposals | Manifold admission, subscriptions, routes, leases, authorization, revisions, audit |
| Optics | camera, image, projection, homography, lens and media metadata contracts | Android permission prompts, APK signing |
| GUI | app-neutral operator UI contracts and CLI parity surfaces | hidden device setup or command business logic |
| Makepad | Makepad adapters, settings surfaces, app-shell integration | Quest platform authority or generic core state |
| Quest | Quest/Horizon/Android platform profiles, permissions, launch, OpenXR bridge/API-layer packaging and effective readback, ADB-facing validation receipts | app semantics or generic command/session authority |
| Hostess | install/test/evidence orchestration, shell UX, Windows media receivers, and opaque operator-presentation adapters such as the bounded Meta/MQDH Cinematic route | Quest runtime feature authority, Meta casting transport, or generic Manifold media authority |
| QuestIonAble File Manager | Windows-first exact-serial ADB storage, inspected APK deployment, constrained resolved launch, bounded device observation, and reviewed local device utilities through typed CLI/API/WPF routes | managed target selection, Manifold authority, Fleet scheduling, app-owned OpenXR/runtime truth |

## Public Rusty XR Compatibility

Rusty XR remains the public compatibility and example core. Do not rename
existing public APIs simply because Morphospace is now the umbrella. Extract
reusable pieces as contracts, helpers, fixtures, and examples first.

## Extraction Gate

Before moving a utility from an app or lab repo into a generic lane:

1. Define the public data shape, schema, scorecard, or validation rule.
2. Add the smallest deterministic helper needed to exercise it.
3. Keep platform calls, renderer ownership, package identity, device mutation,
   and release payloads in adapters or app shells.
4. Add a synthetic test, fixture, source example, or docs matrix entry.
5. Record `owns`, `does_not_own`, app-specific exclusions, dependencies,
   provenance, license, and rollback in a module-candidate record.
6. Reconnect the originating app through the neutral contract.
7. Require an independent consumer or conformance harness before stable
   promotion.

See [Module Lifecycle](MODULE_LIFECYCLE.md) for the complete state machine and
promotion gates.

## Project Composition

Applications select modules in `project.spec.json` and activate them in
`feature.lock.json`. The project owns composition; it does not become the
authority for a reusable module's contract. An unlisted module, a module
without a feature entry, or a disabled feature is inert.

Feature entries must not silently add permissions, routes, assets, services,
media paths, input routes, or private defaults to other projects. See
[Feature Activation](FEATURE_ACTIVATION.md).

## Streaming Placement

Rusty-owned Quest-to-PC streaming keeps Manifold session/stream references,
Quest platform source lifecycle, dedicated high-rate media bytes, Hostess
receiver/presentation, and cleanup evidence under their explicit owners.

An opaque operator-presentation provider is adjacent, not equivalent. The
Hostess Meta/MQDH Cinematic adapter supervises a separately installed Meta
process and reports Hostess observations without receiving generic media
packets. It must not be promoted into a Quest source or Manifold stream, and a
successful Cast window does not prove recording, input forwarding, arbitrary
2D-panel control, Meta device-session cleanup, or FOV restoration.

## First Placement Rules

- Generic spatial relation work starts in Lattice.
- Command/session/stream/control transport starts in Manifold.
- LSL compatibility starts in Rusty LSL; official liblsl is a black-box oracle,
  not a source template or production dependency, and rLSL source is excluded.
- Repeatable local exact-serial storage, inspected APK deployment, constrained
  launch, and bounded device observation start in QuestIonAble File Manager
  when its closed typed registry covers the operation.
- Quest platform profiles and app-owned effective runtime receipts start in
  Quest; portable provider selection, raw diagnostic fallback, and evidence
  wrapping start in Meta Quest workflow.
- OpenXR API-layer loading/interception and co-resident native bridges start in
  Quest or the owning app shell. Portable tracked-space relations remain in
  Lattice; semantic actions remain in the app; command admission remains in
  Manifold.
- Windows receiver/presentation orchestration and opaque Meta/MQDH Cast process
  supervision start in Hostess; version-sensitive capture and evidence
  procedure stays in Meta Quest workflow.
- Managed multi-headset selection and scheduling start in Fleet, with Manifold
  retaining command/lease authority and the effect owner retaining application
  receipts.
- Termux sidecars stay in Quest Termux Lab until a sanitized sidecar contract
  is ready for Rusty Quest sidecar integration.
- Makepad-specific packaging and generated activity behavior stay in the
  Makepad lane or app shell.
- Private app semantics stay private. Public repos may expose generic slots,
  contracts, or scorecards after boundary review.
