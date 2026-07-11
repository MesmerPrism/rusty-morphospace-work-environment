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

### Draft validation-authority boundary

The `MorphospaceOwnership` module and the current-unit, registry, ownership,
validation-v2, trust-migration, and state-transition schemas are a tested but
non-promotional lower-layer draft. They are inert unless explicitly invoked.
Do not use them to claim, validate, accept, recover, or promote a unit until a
tracked owner-validator registry, trust-migration verifier, high validation
authority, transactional state/event integration, public CLI, and their full
damage tests are present.

Ordinary application work may continue through a separate project-local
`morphospace/` workspace and the published workflow. Keep exact repository/path
scope and inert default locks, and do not present draft validation-v2 artifacts
as acceptance evidence.

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
- N-peer membership, coordinator epoch, route ranking, split-brain rejection,
  expiry, revocation, and audit remain Manifold authority. Public-lab and
  sidecar inputs are advisory only; only independently authenticated pairwise
  evidence may produce a direct-lane candidate, and gossip never carries media.
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
  An immutable historical in-flight unit may be excluded from the current
  projection only by an additive
  `<old-unit>-superseded-by-<current-unit>` state-transition event whose
  replacement is the sole current unit; never rewrite the historical unit or
  event prefix to make the workspace look clean.
- Optional work-unit automation is fail-closed: inspect/plan by default,
  require `-Execute` for workspace-state mutation, preserve dirty/divergent
  repositories, derive graph scope from the unit, and never own Git push,
  force-push, checkout/reset/stash, validation execution, or device mutation.
- Move a reviewed proposal into the claimable queue only with the automation
  `Ready` action. It verifies accepted prerequisites, appends the transition,
  and derives `next_ready_unit`; do not hand-edit proposal status.
- New project workspaces default to protocol v2. Resolve exact feature
  descriptors into a fingerprinted closed-world lock; project selection alone
  never activates a run. Runtime effects require the selected current lock and
  one descriptor-approved runtime input, and the effective marker/receipt must
  bind the project, lock revision/fingerprint, and feature.
- Automation may record or accept validation only from a workspace-local
  `validation_receipt.v1` with exact criterion/gate coverage, verified artifact
  hashes, current repo heads/branches, ancestor bases, exact changed paths, and
  required device cleanup plus zero bounded fatals. Reject missing, stale,
  spoofed, or out-of-scope evidence.
- Recovery from a declared partial cross-repo commit, interrupted build, or
  interrupted device run requires `interruption_receipt.v1`. It must hash its
  evidence and prove preserved repo checkpoints plus safe build/device cleanup;
  recovery never performs Git, build-process, or device cleanup itself.
- A prepared push plan is never execution evidence. After an authorized
  external push, validate an `executed_push_receipt.v1` containing full old,
  new, and remote-readback revisions, ancestry, hash-bound validation evidence,
  no-force proof, and reverse-order rollback anchors. A release may additionally
  bind the pre-publication capture that supplied every old revision; multiple
  planning refs must form the final execution suffix.
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
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkUnitAutomation.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FeatureLockResolver.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ExecutedPushReceipt.ps1 -SelfTest
git diff --check
```

If docs or manifests change, also parse JSON files:

```powershell
Get-ChildItem .\manifests,.\schemas,.\templates -Filter *.json -File |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
```
