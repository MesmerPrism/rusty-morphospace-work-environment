# Agent Notes

This repository is intended to be public and portable. Keep committed content
free of local machine paths, private repository names, device serials, package
identities, generated APKs, screenshots, logs, pairing material, signing keys,
and private app payload details.

## Required Routing

Use the local skill templates in `skills/` after installation:

- `rusty-morphospace-context`: repo-family orientation and public/private
  boundary checks.
- `system-engineering`: authority, interface, observability, validation, and
  mitigation-map structure.
- `rust-work-graph`: inventory, source-root maps, and graph snapshots before
  broad refactors.
- `meta-quest-workflow`: live Quest, ADB, APK install/launch, screenshot,
  logcat, Perfetto, Wi-Fi ADB, or Meta tooling operations.

For live headset work, prefer the public `meta-quest-agent-workflow` repository
as the device-operation source of truth. This repo may point to that workflow,
but it should not fork a competing Quest procedure.

## Public Boundary

Use placeholders in public docs:

- `<workspace-root>`
- `<repo-root>`
- `<android-sdk-root>`
- `<android-ndk-root>`
- `<jdk-root>`
- `<openxr-loader-so>`
- `<quest-serial>`
- `<package>`
- `<activity>`
- `<path-to.apk>`
- `<out-dir>`

Do not commit private evidence or local setup output. Keep those under ignored
`local/` or `artifacts/` folders.

## Project Workflow

For project composition, module extraction, explicit activation, or autonomous
iteration, read in this order:

1. `docs/PROJECT_WORKSPACE_PROTOCOL.md`
2. `docs/MODULE_LIFECYCLE.md`
3. `docs/FEATURE_ACTIVATION.md`
4. `docs/AUTONOMOUS_ITERATION.md`
5. `docs/INSTRUCTION_SYNCHRONIZATION.md`

The work-environment repo owns portable schemas, examples, and validators. A
project owns its instantiated `morphospace/` directory. Do not copy live state,
private evidence, or machine paths back into this repository.

## Authority Rules

- Rusty Morphospace names the ecosystem; concrete authority stays in lanes
  such as Matter, Lattice, Manifold, Optics, GUI, Makepad, Quest, Hostess, and
  app shells.
- Core crates start contract-first and dependency-light.
- Android package identity, signing, manifest permissions, OpenXR lifecycle,
  renderer ownership, headset install/launch, and visual validation belong to
  app shells or Quest workflow, not generic core crates.
- Termux is a normal Android sidecar. It can use an already authorized ADB
  endpoint, but it is not shell authority by itself.
- Android properties, JSON profiles, and hotload files are low-rate control
  surfaces. Do not route high-rate camera frames, meshes, particles, depth
  maps, or GPU buffers through them.
- Feature activation is closed-world: absent or unlisted means inert.
- Every mutable parameter has one authority owner; other entrypoints are
  adapters into that owner.
- A reusable module cannot become stable without an independent consumer or a
  neutral conformance harness plus an accepted promotion review.
- Direct networking keeps topology, platform network observation, socket
  ownership, exchange, and cleanup as separate authority surfaces; harnesses
  do not become product dependencies.
- Authenticated rendezvous is evidence only. Peer-session acceptance,
  revision, replay, expiry, peer change, and revocation belong to Manifold;
  product topology requires a fresh current-revision authorization bound to
  exact peer roles and topology contract before platform mutation.
- Generic media composition keeps accepted Manifold session/stream references
  separate from platform lifecycle. Sources, processors, routes, codec/socket
  providers, and sinks stay explicit; compatibility adapters cannot export
  application defaults or permissions into reusable modules.
- Multi-app broker SDKs share only accepted contract families and the minimum
  platform permission. Every app keeps a distinct OS/package identity, client
  id, exact feature lock, marker namespace, grant, and app-local capability;
  pair-level validation must reject ambient unions and cross-app defaults,
  properties, markers, or authority-reset behavior.
- At most one iteration unit is active or validating in a project workspace.
- A downstream adoption unit must be behavior-neutral unless its scope says
  otherwise: select the baseline shell, list optional families disabled,
  assert an unrelated nearby feature is absent/inert, and add candidate records
  before moving reusable source.
- Units changing authority, module layout, activation, validation, device
  policy, repo routing, or public/private boundaries must synchronize the
  nearest repo instructions, a README/router doc, and relevant skills before
  acceptance.
- Keep `AGENTS.md` and `SKILL.md` as routing indexes. Put long recipes in linked
  docs or runbooks.

## Validation

Before committing, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkEnvironment.ps1 -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-ProjectWorkspace.ps1 -SelfTest
git diff --check
```

If docs or manifests change, also parse JSON files:

```powershell
Get-ChildItem .\manifests,.\schemas,.\templates -Filter *.json -File |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
```
