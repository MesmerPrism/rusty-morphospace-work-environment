# Project, Build, And Headset Isolation

Use this protocol when several Rusty Morphospace projects are changing at the
same time, especially when they repeatedly build and launch APKs on one Quest
headset. Parallel source work and parallel builds are safe only when their
mutable identities do not overlap. Runs on one headset are serialized.

## Isolation Contract

Each run is the product of three closed inputs:

1. a declared source composition appropriate to the selected build lane;
2. an app-specific, content-addressed APK and run capsule;
3. a serial-scoped device transaction.

An ambient checkout, environment variable, previous launcher setting, or APK
already installed on the headset is not an input unless the current lock or
run capsule names it.

## Exact Source Composition

Exact clean composition is required for Candidate/publication work and for any
claim that depends on reproducibility. Warm iteration instead records the live
source observation and its limitations; it must not reuse the words
`validated`, `accepted`, or `clean` for that state. Both lanes hand device work
one exact inspected APK digest.

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
  -RepositoryMapPath <local-repository-map> `
  -RepoId <product-repo-id>
```

Pass every intended product repository ID explicitly. Repository-map entries
that provide tooling, device access, or validation evidence must not enter a
source lock merely because they are locally available.

The command plans by default. Add `-Execute` only after reviewing the full
commit/tree set. For separate checkout and build identities, materialize the lock as detached
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

## Durable Supplier Object Storage

A separate checkout or an ordinary `.git` directory does not establish an
independent object store. Linked worktrees share their common Git directory.
A local clone with `--no-hardlinks` can still inherit the source repository's
`objects/info/alternates`; that option controls hard links, not borrowed Git
objects. Such a clone can stop resolving its pinned source after the supplying
repository is retired or its objects disappear.

When a reusable supplier must survive independently of its source checkout,
create a fresh namespace and dissociate borrowed objects during cloning:

```powershell
git clone --no-hardlinks --dissociate --no-checkout <source-repository> <supplier-root>
git -C <supplier-root> remote set-url origin <reviewed-origin-url>
git -C <supplier-root> checkout --detach <exact-source-commit>
```

Require every command to exit successfully. The reviewed origin is the declared
repository identity, not the local source path copied into a clone's default
origin. Retain the original source observation and the actual clone arguments;
changing the locator does not authenticate an otherwise unreviewed supplier.
Do not reuse or repair an existing frozen supplier in place.

Before describing the result as an independent reusable supplier, observe and
retain all of the following through the selected Git executable:

- the exact declared origin, `HEAD` commit and tree, and an empty
  `status --porcelain --untracked-files=all`;
- absolute `rev-parse --git-dir`, `--git-common-dir` and `--git-path objects`
  locations within the supplier's own ordinary `.git` directory, rather than
  a linked or external Git directory;
- absence of both `objects/info/alternates` and `objects/info/http-alternates`,
  including empty files, and no ambient `GIT_DIR`, `GIT_COMMON_DIR`,
  `GIT_WORK_TREE`, `GIT_OBJECT_DIRECTORY` or
  `GIT_ALTERNATE_OBJECT_DIRECTORIES` override;
- successful `git fsck --full`, with the retained source commit/tree still
  resolvable from this object store.

The exact source lock and the consuming owner's source, namespace and
qualification guards remain required. Object independence supplies no new
validation, acceptance, publication or adoption authority.

This lifetime requirement does not forbid declared object sharing. Detached
worktree materializations still isolate checkout writes while depending on
their common repository. Disposable host fixtures may deliberately use
`--shared` or references when that dependency and fixture lifetime are explicit.
Neither is an independent durable supplier; retire its borrower before its
provider. Read-only borrowing alone is not a conflicting source write.

## Build Identity

Every app must keep these identities distinct:

- Android package and launch activity;
- app/client identity, marker namespace, feature lock, grants, and leases;
- immutable APK/evidence output and mutable Gradle/Cargo/Android-shell/product
  intermediate directories;
- runtime property namespace and app-private staging namespace.

Warm intermediates use a deliberately short, stable project- and lane-scoped
root. Separate host Cargo from Android Cargo and separate native,
Android-shell, and package invalidation identities. Do not derive the entire
mutable root from the full product fingerprint. Generated inputs are updated
only when their bytes change, and a writer must hold the root's coordination
claim or mutex.

Locked Candidate/publication builds reject ambient feature variables, require
an exact clean source commit/tree, write immutable content-addressed output,
and emit a run capsule that hashes the APK, build manifest, feature lock,
effective runtime profile, property manifest, and—when QFM is used—the provider
source commit/tree, portable distribution-manifest digest, closure digest, and
staged relative entry point. A provider closure is the declared entry point
plus every required relative runtime file with its size and SHA-256; its staged
run root is content-addressed and verified before and after each typed use.
No public capsule records a machine-local provider path. Reusing or replacing that
content address is an explicit error, not an incremental-build shortcut. This
immutability rule applies to the final output and evidence, not to a separately
declared compiler cache.

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

Claim `repo-path` and each shared build root or `build-output` before writing;
claim `android-package`,
`property-namespace`, `staging-namespace`, and the exact `headset` serial before
install or launch, not while a host-only build is running. `bridge-port` is
available for app-local services. Release
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
