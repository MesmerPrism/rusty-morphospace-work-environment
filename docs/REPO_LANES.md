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
| Quest | Quest/Horizon/Android platform profiles, permissions, launch, ADB-facing validation receipts | generic command/session authority |
| Hostess | install/test/evidence orchestration and shell UX | runtime feature authority |

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

## First Placement Rules

- Generic spatial relation work starts in Lattice.
- Command/session/stream/control transport starts in Manifold.
- LSL compatibility starts in Rusty LSL; official liblsl is a black-box oracle,
  not a source template or production dependency, and rLSL source is excluded.
- Quest install, launch, runtime profiles, Android property hygiene, and
  headset evidence start in Quest or Meta Quest workflow.
- Termux sidecars stay in Quest Termux Lab until a sanitized sidecar contract
  is ready for Rusty Quest sidecar integration.
- Makepad-specific packaging and generated activity behavior stay in the
  Makepad lane or app shell.
- Private app semantics stay private. Public repos may expose generic slots,
  contracts, or scorecards after boundary review.
