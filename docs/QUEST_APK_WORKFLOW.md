# Quest APK Workflow

Use this runbook when building, installing, launching, or validating Quest APKs
for Rusty Morphospace work. For live device operations, use the public
`meta-quest-workflow` skill or the `meta-quest-agent-workflow` repository.

For repeatable agent operations, follow
`meta-quest-agent-workflow/docs/agent-execution-providers.md`. Prefer an owning
application's closed typed CLI or local API when it covers the exact operation
and produces fresh effective readback. QuestIonAble File Manager may own a
local exact-serial inspected deployment; Rusty Fleet may own a managed
multi-target operation only through current Manifold authority and effect-
owner receipts. Their executable requests and receipts are deliberately
different. Keep machine paths, serial aliases, target resolution, credentials,
approvals, and coordination correlations in private resolver/run evidence.
Use direct serial-scoped ADB below as a labeled diagnostic fallback or for
provider-gap recovery, never as substitute owner acceptance.

## Choose The APK Build Lane

Select the build lane independently from `guard_profile`, `risk_tier`,
validation tier, and device-operation authorization:

| Lane | Composition contract | Mutable intermediates | Handoff contract |
| --- | --- | --- | --- |
| Warm iteration | Declare the live source observation, selected features, toolchain, package/signer policy, and limitations. Do not claim a clean composition. | Reuse a stable, deliberately short project- and lane-scoped Cargo/Gradle/Android-shell/product root with explicit invalidation. | Retain the exact inspected thin-development APK digest, focused-check result, build-phase receipt, and invalidation record. |
| Candidate/publication | Freeze an exact clean multi-repository composition and feature/runtime lock. Reject ambient inputs. | Use the build owner's Candidate profile and fresh final assembly boundary; identify any retained compiler cache separately. | Retain content-addressed APK, inspection, signer/toolchain evidence, full gates, composition lock, phase receipt, and run capsule. |

Stable mutable caches and immutable outputs are different identities. Do not
key the whole compiler/Gradle cache by the full APK fingerprint, and do not
replace an existing content-addressed output with an incremental result. Scope
each cache to one project and lane, separate Android Cargo targets from host
targets, write generated build inputs only when their bytes change, and record
native, Android-shell, and package invalidation independently.

Before an expensive build, the owner may run the Work Environment host-only
build-profile preflight. It is advisory evidence, not a central decision and
never produces or replaces the Inspect-owned WorkUnit candidate fingerprint.
It observes the declared build vector and repo-owned toolchain/targets without
injecting versions or targets; it does no build, device, ADB, lease, source
mutation, or publication. See [Exact Quest run profiles](QUEST_RUN_PROFILES.md).

Host compilation requires only the relevant build-root coordination. Acquire
the exact headset claim immediately before an install, launch, or device
observation. A warm build does not authorize a device mutation.

The public
[`Quest APK Build Lanes`](https://github.com/MesmerPrism/meta-quest-agent-workflow/blob/main/docs/quest-apk-build-lanes.md)
playbook owns the portable procedure. The selected app shell or `rusty-quest`
adapter owns concrete modes, inputs, tasks, and inspection. These human-readable
lane names do not import another framework's wrapper schema.

## Default Ecosystem Loop

For routine local iteration:

```text
declared project source + selected build lane + exact APK/run capsule
  -> private hash-pinned File Manager distribution-closure resolution
  -> File Manager artifact inspection and exact-serial install
  -> Kiosk status and typed launch when the app participates
  -> File Manager bounded Android observation
  -> app-owned effective-runtime receipt
  -> owner-specific cleanup readback
```

For a long or interruption-prone run, bind those stages through the read-only
[resumable APK run transaction](APK_RUN_TRANSACTION.md). It audits create-new
phase receipts and selects the first missing phase; it never executes a phase
or grants build, device, acceptance, cleanup, Git, or publication authority.

For enrolled managed targets, replace the local File Manager operation with a
Fleet request over one immutable target snapshot. Require current operator
policy, Manifold authority when applicable, effect-owner delivery/receipts,
and terminal cleanup or reconciliation per target. Do not translate local
File Manager arguments into a Fleet request and do not use local File Manager
to bypass managed policy.

Copy
[`quest-file-manager-cli.example.json`](../templates/quest-file-manager-cli.example.json)
to the ignored `local/quest-file-manager-cli.json`, bind the exact executable
SHA-256 and source revision, and retain the complete inspected-deployment
contract set from that template. The resolver rejects older provider pins that
do not advertise QFM v5 inspected deployment, preflight/deploy, bounded
diagnostic result/bundle, typed stop, shared-forward inventory, one typed JSON
launch envelope on success or failure, the current-Quest launcher-export proof,
runtime observation v5, global-focus observation v1, and read-only permission
observation v1. Resolve the provider
without touching a headset:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Resolve-QuestFileManagerCli.ps1 `
  -ConfigPath .\local\quest-file-manager-cli.json `
  -Json
```

Use the resolved executable for typed `apk inspect`, `apk install`,
`kiosk status`, Kiosk launch control when applicable, `apk launch` otherwise,
and `apk observe`. Kiosk retains catalog, selection, launch, and foreground-
guard authority even when File Manager or Fleet carries its request. Android
foreground observation does not replace app-owned OpenXR, renderer, source, or
feature-lock evidence.

The current File Manager consumer contract preserves owner-native result
schemas rather than wrapping their payloads. Its `apk_launch_result.v1` outer envelope is exactly
`{schema,succeeded,mutation,result,failure}`: success has non-null mutation
and result with null failure; failure has null mutation/result with non-null
failure. Explicit legacy-v3, legacy-v4, and current-v5 adapters keep installed
identity, process, task/top-resumed, and global Android focus distinct. Runtime
v5 adds bounded `mCurrentFocus`/`mFocusedApp` facts through global-focus v1;
these remain raw Android observations. Neither a PID, process liveness,
top-resumed state, target focus, nor FocusPlaceholder state establishes
application/OpenXR readiness, an application effect, or wearer visibility.
`apk permissions` is a separate exact-package, read-only fact family for
manifest declarations, reported grant bits, and app-op modes. It never grants
or revokes permission and cannot establish permission policy, feature use, or
application/OpenXR readiness.

For repeatable local work, use the fail-closed wrapper instead of reconstructing
that sequence from ambient executables. Its default mode resolves the pinned
provider and inspects only the local artifact without touching a headset:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-QuestFileManagerDeployment.ps1 `
  -Mode Inspect `
  -ApkPath <path-to.apk>
```

After reserving the exact `quest:<quest-serial>` resource, run a read-only
installed-artifact check with `-Mode Observe`, or one full non-Kiosk deployment
transaction with `-Mode Deploy`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-QuestFileManagerDeployment.ps1 `
  -Mode Deploy `
  -Serial <quest-serial> `
  -ApkPath <path-to.apk> `
  -EvidenceDirectory .\local\quest-runs\<run-id>
```

`Install` and `Deploy` fail if File Manager returns anything short of exact
headset-confirmed artifact readback. Every device mode requires a new
run-owned evidence directory, makes content-addressed read-locked copies of
the APK and the complete hash-pinned provider closure (entry point plus every
declared runtime sibling), and retains the provider source commit/tree,
distribution-manifest digest, closure digest, staged relative entry point, and
provider resolution plus
exact JSON and execution evidence for each attempted typed step. In-repository
evidence is accepted only below ignored `local/` or `artifacts/`. Use
`-Mode Install`, then Kiosk's typed status/launch route, for an app whose launch
authority belongs to Kiosk.

The pinned `.exe` provider is Windows-hosted. Windows self-tests therefore
require the open read lease to reject mutation. Portable non-Windows CI does
not treat `FileShare` as a Windows-style mutation lock; it verifies the exact
content-addressed filename and retained hash instead, and reports the host lock
result separately.

Routine portable intents set `raw_fallback_allowed=false`. Before a raw ADB
fallback, record the intended provider/version, missing or failed capability,
unavailable claim, bounded diagnostic or recovery scope, stop condition,
cleanup, and product improvement follow-up.

## Authority Split

| Surface | Owner |
| --- | --- |
| Contracts, schemas, synthetic fixtures | public core or clean Morphospace lane |
| Project composition, feature lock, build-lane isolation, and run capsule | Work Environment and project workflow |
| Cargo/Gradle/Android assembly implementation and APK inspection | App shell or Rusty Quest adapter |
| Android package identity and signing | app shell |
| Manifest permissions and activity declarations | app shell or Quest build workflow |
| OpenXR loader, Vulkan/GL setup, swapchains, frame loop | app shell or renderer adapter |
| OpenXR API-layer package/manifest, activation, call interception, and effective readback | app shell plus Quest adapter |
| Semantic XR actions and panel/entity meaning | app shell |
| Accepted commands, leases, replay, revocation, and control transport | Manifold |
| Install, launch, logcat, screenshots, Perfetto | Meta Quest workflow |
| App-specific assets, payloads, tuning, screenshots | app repo or private evidence store |

## Host Build Preflight

Verify:

```powershell
git --version
cargo --version
rustup target list --installed
java -version
javac -version
adb version
```

Install the Android Rust target:

```powershell
rustup target add aarch64-linux-android
```

Keep SDK paths explicit in evidence commands:

```powershell
$env:RUSTY_XR_ANDROID_SDK_ROOT = "<android-sdk-root>"
$env:RUSTY_XR_ANDROID_NDK_ROOT = "<android-ndk-root>"
$env:RUSTY_XR_ANDROID_JDK_ROOT = "<jdk-root>"
$env:RUSTY_XR_OPENXR_LOADER_QUEST = "<openxr-loader-so>"
```

## Public Rusty XR Examples

Minimal Android smoke APK:

```powershell
pwsh -ExecutionPolicy Bypass `
  -File .\examples\quest-minimal-apk\tools\Build-QuestMinimalApk.ps1
```

OpenXR/Vulkan composite example:

```powershell
pwsh -ExecutionPolicy Bypass `
  -File .\examples\quest-composite-layer-apk\tools\Build-QuestCompositeLayerApk.ps1 `
  -AndroidSdkRoot <android-sdk-root> `
  -AndroidNdkRoot <android-ndk-root> `
  -JdkRoot <jdk-root> `
  -OpenXrLoaderPath <openxr-loader-so>
```

OpenXR/OpenGL ES video-stack feasibility example:

```powershell
pwsh -ExecutionPolicy Bypass `
  -File .\examples\quest-gl-openxr-video-stack-apk\tools\Build-QuestGlOpenXrVideoStackApk.ps1 `
  -OpenXrLoaderPath <openxr-loader-so>
```

Generated outputs stay in ignored build folders in the source repo.

## Makepad Quest Build Shape

Use Makepad's Android packager for Makepad examples. Keep host Rust checks and
Android package checks separate.

```powershell
cargo check --manifest-path <makepad-app>\Cargo.toml
cargo test --locked --manifest-path <makepad-app>\Cargo.toml
```

Then package:

```powershell
cargo makepad android `
  --abi=aarch64 `
  --variant=quest `
  --sdk-path=<android-sdk-root> `
  --package-name=<public-example-package> `
  --app-label="<app-label>" `
  build -p <makepad-app-package> --release
```

For install/run:

```powershell
cargo makepad android `
  --devices=<quest-serial> `
  --abi=aarch64 `
  --variant=quest `
  --sdk-path=<android-sdk-root> `
  --package-name=<public-example-package> `
  --app-label="<app-label>" `
  run -p <makepad-app-package> --release
```

Do not treat a direct `cargo check --target aarch64-linux-android` as the full
Makepad Android acceptance gate. It compiles Rust for the target, but it does
not exercise generated Android activity and package behavior.

## Raw ADB Install And Launch Fallback

Use one shared default ADB daemon for all connected headsets. Device discovery
and independent clients may run concurrently, but every device command must use
`adb -s <serial> ...`. Under Agent Board coordination, reserve the exact
`quest:<serial>` for exclusive headset work. Reserve `adb-server:lifecycle`
only before global operations such as killing, starting, restarting, recovering,
or replacing the daemon; configuring Wi-Fi ADB; changing keys; or owning an
alternate server port. Do not use the legacy broad `adb-server` lease for
routine serial-scoped work.

When several projects share one headset, do not launch from a loose APK path
plus ambient properties. Require an app-specific run capsule that binds the
APK, package/activity, build manifest, feature lock, effective runtime profile,
complete property manifest, and exact source commit/tree. Keep package,
client/marker identity, build output, Gradle/Cargo intermediates, property
namespace, and staging namespace distinct per project.

Parallel builds are allowed only for disjoint identities. Install/launch runs
on the same serial are exclusive transactions. Follow
[Project, Build, And Headset Isolation](PROJECT_ISOLATION.md).

Only after the provider-gap fallback is recorded, use serial-scoped ADB:

```powershell
adb -s <quest-serial> install -r -d -g <path-to.apk>
adb -s <quest-serial> shell am start -W -n <package>/<activity>
```

For cold-start testing:

```powershell
adb -s <quest-serial> shell am force-stop <package>
adb -s <quest-serial> shell am start -W -n <package>/<activity>
```

Treat `force-stop` as a lifecycle mutation. It can affect services, panels,
immersive state, and broker surfaces.

## Managed Store Apps And Launcher Lifecycle

Before validating Meta Horizon Store content on an organization-managed
headset, identify Individual versus Shared Mode and the active Android
user/profile. Individual Mode can expose the consumer Store when administrator
policy permits it. Shared Mode uses a separate managed catalog and must not be
treated as equivalent consumer-Store or paid-entitlement access.

Read-only automation may resolve and inspect the Store package, effective user
restrictions, and launcher component. Opening that component proves only that
the Store Activity ran. The wearer must choose and buy a title, enter Store PIN
or payment data, accept terms, and report that installation completed. Keep
account identifiers, payment state, raw policy dumps, and package inventories
private.

When launcher behavior is under test, distinguish tasks from processes. A
fresh target task can recreate the Activity and Spatial/OpenXR scene while
Android retains the same Linux process. Background tasks are normal cached
state; do not add shell, device-owner, or arbitrary force-stop authority merely
for cleanup. Use an operator-authorized, serial-scoped `am force-stop` only for
a named cold-process validation.

Route the detailed public procedure to
`meta-quest-agent-workflow/docs/managed-device-store-apps.md`.

## Accessibility Foreground Watchdogs

For an attended watchdog that restores an exported app after Meta Home or
another top-level window replaces it, route to the public
`meta-quest-agent-workflow` guide
`docs/accessibility-foreground-watchdogs.md`. Keep UI-content retrieval
disabled, treat exact Meta package/class signals as Horizon-version-specific,
and separate refocus scheduling from distinct Home-invocation escape counting.

Accessibility is not HOME ownership, lock-task mode, or managed-device
authority. If the normal Accessibility settings surface is unavailable, any
ADB enablement is explicit development-headset setup and must preserve the
existing enabled-service list. Termux may perform that setup only through an
already authorized ADB shell lease that reports `uid=2000(shell)`.

Before a run, take a per-serial mutex/claim and snapshot the complete declared
property set. Clear that set before applying the selected profile. In a
`finally` path, stop only the target package, restore exact prior values,
verify cleanup, and write a transaction receipt. Do not force-stop known XR
packages as a blanket preflight and do not use another project's installed APK
or launcher residue as a default.

## Crash Watch

Use a bounded output directory:

```powershell
New-Item -ItemType Directory -Force <out-dir> | Out-Null
adb -s <quest-serial> logcat -c
adb -s <quest-serial> shell am start -W -n <package>/<activity>
Start-Sleep -Seconds 10
adb -s <quest-serial> logcat -d -v threadtime > <out-dir>\logcat.txt
adb -s <quest-serial> shell pidof <package> > <out-dir>\pid.txt
adb -s <quest-serial> shell dumpsys window > <out-dir>\dumpsys-window.txt
```

Search for:

- `FATAL EXCEPTION`
- `AndroidRuntime`
- `UnsatisfiedLinkError`
- `Unable to find native library`
- missing permission strings
- OpenXR loader or extension errors
- repeated pause/resume/focus/window loops
- renderer frame counters or fallback clear logs

## OpenXR Bring-Up Gates

Durable success signals:

- OpenXR loader initialized with the foreground Activity context.
- The app waits for resumed, focused, and native-window-ready state before
  creating or beginning the session.
- Session advances through `READY`, `SYNCHRONIZED`, `VISIBLE`, and `FOCUSED`.
- Swapchains are created at headset eye resolution.
- Frame logs continue after the first submitted frame.
- A bright fallback clear or synthetic pattern proves renderer liveness before
  camera, stream, or depth ingestion is debugged.

## OpenXR Integration Choice

Choose the narrowest integration shape that provides the required evidence or
effect:

| Shape | Use it for | Do not claim |
| --- | --- | --- |
| App-owned native OpenXR | Owning the instance, session, actions, spaces, swapchains, and frame loop. | That another component may also own frame wait/begin/end. |
| Co-resident Meta Spatial SDK bridge | Reusing the SDK-owned instance, session, and `xrGetInstanceProcAddr` handle for compatible functions and enabled extensions. | That resolving a function transfers session, frame-loop, composition, or semantic ownership. |
| OpenXR API layer | Observing or interposing the app-to-runtime call chain, including lifecycle, poses, actions, haptics, and submitted composition metadata. | Generic engine UI semantics, system-wide Touch input, post-instance attachment, or injection into arbitrary installed apps. |

For Android, an ordinary layer is part of the target APK feature closure: pin
its ABI library, JSON manifest, explicit/implicit activation route, layer order,
IPC surface, cleanup behavior, and effective app-visible readback. A Termux or
host process may be a bounded typed client only after the target APK has loaded
the layer. Keep high-rate pose/image/depth data out of generic command JSON.

The canonical capability and packaging model is the Meta Quest workflow's
[`openxr-tracking-boundary.md`](https://github.com/MesmerPrism/meta-quest-agent-workflow/blob/main/docs/openxr-tracking-boundary.md).

## Device Evidence

For product Wi-Fi Direct tests, keep Android group topology, public `Network`
observation, Rust-owned explicit `p2p0` sockets, bounded non-media exchange,
and cleanup as separate evidence rows. A valid `p2p0` route may exist without
a public Android `Network`; report that absence rather than inventing a
binding. Require both peers to return to inactive state and scan the bounded
window for both package and system fatals.

Publish sanitized summaries only. Keep raw artifacts private:

- serials;
- logcat;
- screenshots;
- Perfetto traces;
- package identities for private apps;
- generated APKs;
- local artifact paths.
