# Rusty Morphospace Work Environment

Portable onboarding and project-iteration workspace for Rusty Morphospace
development.

PowerShell `7.6` LTS or newer, invoked explicitly as `pwsh`, is the supported
workflow host. Windows PowerShell 5.1 may run the bootstrap host check, but it
is not an execution environment for validation, automation, builds, or release
tooling. PowerShell 7 installs side by side with 5.1 on Windows.

Current work-environment protocol release: `0.6.0` (2026-07-23). It adds
hash-bound adoption of immutable terminal work, exact planned and unplanned
publication accounting, protected-branch source resolution, and bounded
recovery for already-published planning suffixes. Its machine-readable release
surface is the [0.6.0 manifest](manifests/release-0.6.0.json); the principal
operational entrypoints are
[Historical Unit Adoption](docs/HISTORICAL_UNIT_ADOPTION.md) and
[Planned Publication Accounting](docs/PLANNED_PUBLICATION_ACCOUNTING.md).
The release also carries opt-in Quest Accessibility watchdog routing while
preserving managed provisioning as the preferred kiosk lifecycle. It does not
change the separately governed Rusty Morphospace platform/runtime baseline.

The published [0.5.0 manifest](manifests/release-0.5.0.json) remains the
project/source/build/run isolation baseline, and the
[0.4.0 manifest](manifests/release-0.4.0.json) remains the immutable
release-capsule and local-skill onboarding baseline. Earlier manifests remain
readable. Existing project instances adopt later baselines additively:
preserve live events and receipts, normalize portable change categories while
retaining domain detail in `tags`, and validate before using the optional
automation CLI.

Terminal historical units with legacy workflow vocabulary use the explicit
[historical unit adoption contract](docs/HISTORICAL_UNIT_ADOPTION.md). Its
project receipt binds exact bytes and normalization, including exact legacy
instruction-impact and surface-action mismatches; current portable registries
and all current/future instruction rules remain closed.

Portable project, unit, repository, feature, receipt, and event identities use
lowercase alphanumeric/hyphen syntax and support 2 through 128 characters.
Authority-stage protocols may declare a wider identity domain explicitly.

This repository packages the agent instructions, setup notes, dependency
matrix, validation scripts, and local-skill templates needed to bring up a
new contributor environment without relying on one maintainer's machine paths.

## Scope

Included:

- workspace layout and repo-lane orientation;
- dependency matrix for Rust, Android, Quest APK, Makepad, Termux sidecar, and
  agent workflows;
- portable skill templates for Morphospace routing, system engineering,
  Rust workspace graph audits, and Meta Quest workflow handoffs;
- project-local composition, feature activation, module extraction, promotion,
  and autonomous-iteration contracts;
- exact source-composition locks, detached materializations, resource claims,
  and repeated same-headset APK-run isolation contracts;
- JSON schemas, public examples, validators, and a no-overwrite project
  scaffold for those contracts;
- setup examples that use placeholders such as `<workspace-root>`,
  `<android-sdk-root>`, `<quest-serial>`, and `<path-to.apk>`;
- public/private boundary rules for notes, logs, APKs, screenshots, package
  identities, generated artifacts, and live headset evidence.

Not included:

- SDKs, APKs, OpenXR loader binaries, signing keys, screenshots, logcat dumps,
  device serials, or local tool caches;
- private planning state or private app payload details;
- a promise that ADB, Termux, shell helpers, or Meta tooling can bypass Quest
  platform permissions.

## Fast Path

1. Run `pwsh -NoProfile -File .\scripts\Test-PowerShellHost.ps1` and read
   [Setup Overview](docs/SETUP_OVERVIEW.md).
2. Fill a private copy of [local.paths.example.json](templates/local.paths.example.json).
3. Run the environment smoke test:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkEnvironment.ps1 `
  -ConfigPath .\local\local.paths.json `
  -Profile Core `
  -Strict
```

4. Read [Local Skill Bootstrap](docs/LOCAL_SKILL_BOOTSTRAP.md), then plan,
   install, and verify the four skill routers:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot <codex-skills-root> `
  -Action Plan

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot <codex-skills-root> `
  -Action Install `
  -Execute

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot <codex-skills-root> `
  -Action Verify
```

5. For a new or existing application, read
   [Project Workspace Protocol](docs/PROJECT_WORKSPACE_PROTOCOL.md), then run a
   protocol-v2 scaffold dry run (v1 remains readable for existing workspaces):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-ProjectWorkspace.ps1 `
  -ProjectRoot <project-root> `
  -ProjectId <project-id>
```

6. For Quest APK work, read [Quest APK Workflow](docs/QUEST_APK_WORKFLOW.md)
   and use the public Meta Quest workflow repo as the device-operations
   authority.

The checked-in [Hello Morphospace V2](examples/hello-morphospace-v2/README.md)
workspace demonstrates an inert lock, a proposed bounded unit, and semantic
validation without a device.

## Project Iteration

- [Project Workspace Protocol](docs/PROJECT_WORKSPACE_PROTOCOL.md) defines the
  project-local control surface and agent resume order.
- [Module Lifecycle](docs/MODULE_LIFECYCLE.md) defines extraction and stable
  promotion, including the second-consumer gate.
- [Feature Activation](docs/FEATURE_ACTIVATION.md) makes absent features inert
  and requires one parameter authority plus a fingerprinted selected lock,
  explicit runtime input, and effective-runtime receipts.
- [Autonomous Iteration](docs/AUTONOMOUS_ITERATION.md) defines work-unit scope,
  compact state, event notes, validation tiers, larger push checkpoints, and
  the optional fail-closed work-unit automation CLI.
- [Project, Build, And Headset Isolation](docs/PROJECT_ISOLATION.md) separates
  concurrent source/build identities while serializing transactional runs on
  one headset.
- [Instruction Synchronization](docs/INSTRUCTION_SYNCHRONIZATION.md) keeps
  skills, planning instructions, touched-repo `AGENTS.md`, and README/router
  docs aligned without duplicating long recipes.
- [Release Capsules And Historical Closure](docs/RELEASE_CAPSULE_AND_HISTORICAL_CLOSURE.md)
  separates an exact candidate cut from later ancestry-based audit closure, so
  normal post-release commits and dirty local work do not rewrite a release.

This repository owns the portable protocol. The project adopting it owns its
live `morphospace/` state and evidence.

Receipt-security corrective units use a stricter hash-pinned runner and derived
v2 receipt. Preflight remains non-promotional. See
[Advanced Validation Authority](docs/VALIDATION_AUTHORITY_ADVANCED.md) before
changing that path or running its Deep tests.

New scaffolds use `project_spec.v2`, `feature_lock.v2`, and
`workspace_state.v2`. Exact feature descriptors resolve through
`scripts/Resolve-FeatureLock.ps1`; `scripts/Test-FeatureActivationAgainstLock.ps1`
provides the fail-closed selection/fingerprint/runtime-input gate. Existing v1
workspaces remain valid and migrate additively rather than being rewritten.
Resolver filesystem paths are local adapter inputs only: v2 locks retain
forward-slash descriptor references relative to `project.spec.json` and reject
absolute, parent-traversing, or out-of-project descriptor locations.
If a corrective unit supersedes an immutable historical active/validating
unit, append the exact
`<old-unit>-superseded-by-<current-unit>` state-transition event and keep the
replacement as the sole current unit; do not rewrite the old unit or event
prefix.

The automation CLI inspects or plans by default. `-Execute` is required for a
workspace-state transition; it still does not run Git push, force-push,
checkout/reset/stash, validation commands, or live device commands.
Use `-Action Ready -Execute` to review a bounded `proposed` unit into the
claimable queue after its prerequisites are accepted; this replaces manual
status/state/event edits.
`RecordValidation` and `Accept` require a local `validation_receipt.v1` whose
hashed artifacts, exact acceptance/gate coverage, repository revisions,
changed paths, and required device cleanup/fatal fields still match current
state.
Interrupted cross-repo commits, builds, and device runs resume only from a
validated `interruption_receipt.v1`; the automation restores workflow state
after cleanup evidence exists but never performs the external cleanup.
Work already in flight before protocol v2 can cross the normal dirty-claim
gate only through a generated `inflight_adoption_receipt.v1` that exactly
hashes every dirty in-scope file or deletion and becomes stale on any change.
Prepared push plans use `execution: not-performed`. After an authorized
external push, `executed_push_receipt.v1` records exact old/new/readback refs,
ancestry, hash-bound validation files, a pre-publication capture when required,
planning-final-suffix order, no-force proof, and rollback points;
validate it with `scripts/Test-ExecutedPushReceipt.ps1`.
Use `scripts/Invoke-ProtectedBranchPushGuard.ps1` when a local pre-push hook
must canonicalize an explicit source selector such as `HEAD`; it binds the
destination to the exact attached protected branch before plan validation.

After a prepared push is externally executed, use
`planned_publication_accounting.v1` and the fail-closed `RecordPublication`
action to enumerate every published commit, preserve carried blocked-unit
status without claiming acceptance, validate the single planning-transport
suffix, and consume only the exact pending bundle. Prepared evidence may bind
standalone plan/event files or their immutable automation-receipt and
transition-ledger containers. See
[`docs/PLANNED_PUBLICATION_ACCOUNTING.md`](docs/PLANNED_PUBLICATION_ACCOUNTING.md).
An immutable executed bundle followed by a separately accepted workflow
correction uses the additive intervening-publication recovery, which binds the
exact fast-forward commits and paths through current clean remote readback. It
preserves the original readback-only nonclaim and is never general drift
tolerance.
Its live prerequisite may contain only the new accounting receipt when the
unchanged executed receipt path/hash is already proven exactly once in the
enumerated intervening planning history; ordinary accounting remains two-path.
A no-force prerequisite suffix that was already published before
`RecordPublication` uses the separate
`published_prerequisite_suffix_reconciliation.v1` evidence contract and
`ReconcilePublishedPrerequisiteSuffix` action. That route accepts only one
planning commit containing exactly the bound executed-push and accounting
receipt paths, with unchanged source refs; it does not broaden ordinary
accounting or tolerate rewrites.
The additive v2 form accepts only an exact two-commit linear suffix when the
second commit corrects the accounting receipt and both commits remain confined
to those same two receipt paths; all identities are full 40-hex revisions.
A later force-with-lease replacement of a published planning-only finalization
suffix uses the cardinality-bounded additive incident recovery documented in
[`PLANNED_PUBLICATION_ACCOUNTING.md`](docs/PLANNED_PUBLICATION_ACCOUNTING.md);
it preserves the earlier no-force execution and rejects any source rewrite.

Push preparation now requires one distinct external planning repository that
contains the active project workspace. The source refs remain first and that
planning ref is the final prepared suffix. If a source push already occurred
without `PreparePush`, preserve the real publication and use the additive
`unplanned_publication_closure.v1` plus `ReconcilePublication`; never create a
retrospective plan or relabel the reconstruction as an executed-push receipt.
If the project workspace was embedded in that source, first project its exact
published-tree bytes to distinct external planning with
`planning_workspace_projection.v1`, then use
`unplanned_publication_closure.v2`. See
[External Planning Projection And Historical Reconstruction](docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md).
If planning alone published early while every source remote remains unchanged,
use the hash-bound publication-ordering interruption input to create a fresh
plan that preserves the fault and claims no publication or corrected order.

Seal coordinated releases with `release_capsule.v1`. At publication,
`Test-ReleaseCapsule.ps1 -Mode CandidateCut` requires every declared remote ref
to equal the pinned commit. Later, `-Mode HistoricalClosure` requires the
pinned commit to remain an ancestor-or-equal while verifying the exact clean
tree in isolation. The validator observes active worktrees but never mutates
them or treats their overlays as release payload.

The first downstream adoption proof lives in Rusty Quest's public
`apps/spatial-camera-panel-android/morphospace/` directory. It demonstrates a
behavior-neutral bootstrap: one selected base shell, explicit disabled optional
families, one absent/inert nearby feature, candidate records, a compact next
unit, and a project-owned static gate.

## Repository Layout

```text
AGENTS.md
README.md
docs/
examples/
manifests/
schemas/
scripts/
skills/
templates/
```

The repo is designed to be cloned beside source repositories, for example:

```text
<workspace-root>/
  rusty-morphospace-work-environment/
  repos/
    Rusty-XR/
    Rusty-XR-Companion-Apps/
    rusty-manifold/
    rusty-manifold-packages/
    rusty-matter/
    rusty-optics/
    rusty-lattice/
    rusty-lsl/
    rusty-gui/
    rusty-quest/
    rusty-hostess/
    rusty-quest-sidecar-mesh/
    makepad-morphospace/
```

The exact layout is not mandatory. Store local paths in ignored files under
`local/` or in your shell profile, not in committed docs.

## Public Upstreams

- Rusty Morphospace Work Environment: `https://github.com/MesmerPrism/rusty-morphospace-work-environment`
- Rusty XR public core: `https://github.com/MesmerPrism/Rusty-XR`
- Rusty LSL: `https://github.com/MesmerPrism/rusty-lsl`
- Meta Quest agent workflow: `https://github.com/MesmerPrism/meta-quest-agent-workflow`
- Quest Termux Lab: `https://github.com/MesmerPrism/quest-termux-lab`
- Rusty Quest sidecar mesh: `https://github.com/MesmerPrism/rusty-quest-sidecar-mesh`

These repositories remain their own sources of truth. This workspace repo
collects the onboarding path across them.

## License

AGPL-3.0-or-later. See `LICENSE`.

Planned publication accounting can fail closed over an immutable executed
range containing multiple separately accepted units while retaining its one
prepared trigger. See `docs/PLANNED_PUBLICATION_ACCOUNTING.md`.
