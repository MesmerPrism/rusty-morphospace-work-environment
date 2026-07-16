# Project, Build, And Headset Isolation

Use this protocol when several Rusty Morphospace projects are changing at the
same time, especially when they repeatedly build and launch APKs on one Quest
headset. Parallel source work and parallel builds are safe only when their
mutable identities do not overlap. Runs on one headset are serialized.

## Isolation Contract

Each run is the product of three closed inputs:

1. an exact multi-repository source composition;
2. an app-specific, content-addressed build;
3. a serial-scoped device transaction.

An ambient checkout, environment variable, previous launcher setting, or APK
already installed on the headset is not an input unless the current lock or
run capsule names it.

## Exact Source Composition

`repository_heads` is an observation surface. It does not claim that the same
revisions were validated or accepted. Protocol-v2 state may therefore keep a
`repository_checkpoints` row per repository with separate `observed_head`,
`claimed_head`, `validated_head`, and `accepted_head` values.

Before cross-repository implementation or module extraction, create an exact
composition lock from clean tracked commits:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-SourceCompositionLock.ps1 `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepositoryMapPath <local-repository-map>
```

The command plans by default. Add `-Execute` only after reviewing the full
commit/tree set. For the strongest isolation, materialize the lock as detached
clean worktrees under a project-specific local root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-SourceMaterialization.ps1 `
  -LockPath <source-composition-lock> `
  -RepositoryMapPath <local-repository-map> `
  -MaterializationRoot <local-materialization-root> `
  -Execute
```

The materialization is content addressed, refuses replacement, and preserves
sibling repository leaf names so relative cross-repository dependencies still
resolve. The lock excludes tracked changes and untracked files; commit an
intentional source slice before locking it.

## Build Identity

Every app must keep these identities distinct:

- Android package and launch activity;
- app/client identity, marker namespace, feature lock, grants, and leases;
- build output and Gradle/Cargo intermediate directories;
- runtime property namespace and app-private staging namespace.

Locked builds should reject ambient feature variables, require an exact clean
source commit/tree, write to a content-addressed output, and emit a run capsule
that hashes the APK, build manifest, feature lock, effective runtime profile,
and property manifest. Reusing or replacing a content address is an explicit
error, not an incremental-build shortcut.

## Cooperative Resource Claims

Declare expected mutable resources in the iteration unit and acquire them
immediately before the relevant write or run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-ResourceClaim.ps1 `
  -Action Acquire `
  -ClaimId <claim-id> `
  -ProjectId <project-id> `
  -UnitId <unit-id> `
  -ResourceKind android-package `
  -ResourceId <package> `
  -DurationMinutes 60 `
  -Execute
```

Claim `repo-path` and `build-output` before writing; claim `android-package`,
`property-namespace`, `staging-namespace`, and the exact `headset` serial before
install or launch. `bridge-port` is available for app-local services. Release
claims in a `finally` path. Claims are machine-local coordination evidence;
they do not authorize device work, Git publication, or feature activation.

## Repeated Runs On One Headset

Different projects may build concurrently when all build and package
identities are disjoint. Only one project may mutate a given headset at a
time. A device runner must:

1. take a per-serial exclusive run mutex and headset claim;
2. validate the run capsule before installation;
3. snapshot every property in the app's complete property manifest;
4. clear that complete manifest, then apply only the selected profile;
5. install, force-stop, and launch only the capsule's package;
6. collect bounded evidence;
7. in `finally`, force-stop only that package and restore the exact prior
   property values;
8. verify cleanup and write a transaction receipt before releasing the serial.

Do not force-stop, uninstall, clear data for, or rewrite properties belonging
to unrelated projects as generic preflight. A stale setting is a cleanup
failure of the run that introduced it, not permission for the next run to
mutate every neighboring app.

## Module Extraction

Reusable code crosses from an app only through a
`module_extraction_receipt.v1`. The receipt binds the exact source-composition
lock, source and target commits/trees and paths, neutral contract, excluded app
details, dependency audit, disabled default activation, private-payload
absence, and validation. A v2 stable promotion review hashes that receipt and
must pass the `extraction-boundary` gate.

This allows a project to originate a generic module without making the
originating app, its package, assets, permissions, settings, or launcher state
part of the reusable default.
