# Quest APK Workflow

Use this runbook when building, installing, launching, or validating Quest APKs
for Rusty Morphospace work. For live device operations, use the public
`meta-quest-workflow` skill or the `meta-quest-agent-workflow` repository.

## Authority Split

| Surface | Owner |
| --- | --- |
| Contracts, schemas, synthetic fixtures | public core or clean Morphospace lane |
| Android package identity and signing | app shell |
| Manifest permissions and activity declarations | app shell or Quest build workflow |
| OpenXR loader, Vulkan/GL setup, swapchains, frame loop | app shell or renderer adapter |
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

## Install And Launch

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

Use serial-scoped ADB:

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
