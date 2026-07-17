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

Install and verify them through `docs/LOCAL_SKILL_BOOTSTRAP.md` and
`scripts/Install-LocalSkills.ps1`. Managed writes require `-Execute`; updates
create a backup and must not delete unmanaged local files.

Use PowerShell `7.6` LTS or newer through the `pwsh` executable for every
authoritative workflow, child runner, validation command, and documented
example. Windows PowerShell 5.1 is bootstrap detection only; do not add new
`powershell.exe`, `& powershell`, or `shell: powershell` execution paths.

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
5. `docs/PROJECT_ISOLATION.md`
6. `docs/INSTRUCTION_SYNCHRONIZATION.md`

For broad validation, use `Test-WorkEnvironment.ps1 -SelfTest -Tier Quick`,
then `Standard`, then `Deep` only when the risk warrants it. A single failed
child check fails the aggregate. These tiers never authorize device work.

The work-environment repo owns portable schemas, examples, and validators. A
project owns its instantiated `morphospace/` directory. Do not copy live state,
private evidence, or machine paths back into this repository.

Portable composition and iteration IDs have one 2-through-128-character
lowercase alphanumeric/hyphen domain across their schemas and validators.
Changes to that domain require passing boundary coverage at 64, 65, 128, and
129 characters. Separately versioned authority-stage IDs may declare wider
bounds explicitly.

### Staged validation-authority boundary

The ownership, registry, trust migration, closed-room validation-v2, and
transactional state/event layers form a staged corrective authority path. A
receipt-security record attempt must pass the quick workspace contract, select
a hash-pinned runner release, seal an exact content-addressed input capsule,
probe the child host, and publish a same-input typed validator-admission result
before the nonce-bound authority runner can record evidence. The admission
probe verifies the sealed validator, unit contract, command identities, and
acceptance bindings without executing acceptance commands. Preflight is
fail-fast admission only and does not prove validation, acceptance, device
behavior, or an external operation.

Keep Git ownership observation bounded by aggregate tree/index/diff calls plus
leased worktree bytes and repeated aggregate boundaries; never scale protected
Git subprocess count per dirty path.

Every authority stage preserves a typed, bounded result and input identities
before cleanup. Reuse a clean-room cache only after the capsule, runner,
materialization, host, and fresh fingerprint checks match exactly; partial,
tampered, stale, or mismatched caches reject and clean up only their owned
temporary paths. Ordinary application work remains in a separate project-local
`morphospace/` workspace with exact path scope and inert default locks. Never
present recovery-source tests as acceptance of the central corrective unit.
Keep canonical authority documents schema-pure: path/location metadata belongs
in runner variables or typed reference wrappers, never injected properties.

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
- Cross-repository implementation and module extraction use an exact source
  composition lock; use detached clean materializations when working copies
  are changing in parallel. Observed, claimed, validated, and accepted
  revisions are separate state.
- Parallel APK builds require distinct package/client identities,
  content-addressed outputs, and complete run capsules. Runs on one headset
  are serial-scoped transactions that restore exact prior properties and
  stop only the target package.
- Machine-local resource claims coordinate repo paths, build outputs, Android
  packages, property/staging namespaces, bridge ports, and headset serials.
  Claims do not activate features or authorize Git/device operations.
- Optional work-unit automation is fail-closed: inspect/plan by default,
  require `-Execute` for workspace-state mutation, preserve dirty/divergent
  repositories, derive graph scope from the unit, and never own Git push,
  force-push, checkout/reset/stash, validation execution, or device mutation.
- Move a reviewed proposal into the claimable queue only with the automation
  `Ready` action. It verifies accepted prerequisites, appends the transition,
  and derives `next_ready_unit`; do not hand-edit proposal status.
- New project workspaces default to protocol v2. Resolve exact feature
  descriptors into a fingerprinted closed-world lock. Descriptor filesystem
  locations are resolver inputs only; the lock records forward-slash paths
  relative to `project.spec.json` and rejects absolute, parent-traversing, or
  out-of-project locations. Project selection alone never activates a run.
  Runtime effects require the selected current lock and one descriptor-
  approved runtime input, and the effective marker/receipt must bind the
  project, lock revision/fingerprint, and feature.
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
- `PreparePush` requires one distinct external planning repository containing
  the active project workspace. A source-only same-ref workspace may not claim
  planning-last closure. If a push preceded preparation, preserve chronology
  with `unplanned_publication_closure.v1` and the workflow-only
  `ReconcilePublication` transition; never fabricate a plan or mutate Git from
  recovery.
- Seal a coordinated release with `release_capsule.v1`: exact remote equality
  and branch convergence belong to the candidate cut, while later historical
  closure requires ancestor-or-equal remote refs and an isolated exact clean
  tree. Observe active worktrees without mutating them or treating overlays as
  release payload. Route details to
  `docs\RELEASE_CAPSULE_AND_HISTORICAL_CLOSURE.md`.
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
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PowerShellHost.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkEnvironment.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-ProjectWorkspace.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkUnitAutomation.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FeatureLockResolver.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ProjectIsolation.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ExecutedPushReceipt.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ReleaseCapsule.ps1 -SelfTest
git diff --check
```

If docs or manifests change, also parse JSON files:

```powershell
Get-ChildItem .\manifests,.\schemas,.\templates -Filter *.json -File |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
```
