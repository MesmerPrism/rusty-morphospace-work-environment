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
powershell -ExecutionPolicy Bypass `
  -File .\examples\quest-minimal-apk\tools\Build-QuestMinimalApk.ps1
```

OpenXR/Vulkan composite example:

```powershell
powershell -ExecutionPolicy Bypass `
  -File .\examples\quest-composite-layer-apk\tools\Build-QuestCompositeLayerApk.ps1 `
  -AndroidSdkRoot <android-sdk-root> `
  -AndroidNdkRoot <android-ndk-root> `
  -JdkRoot <jdk-root> `
  -OpenXrLoaderPath <openxr-loader-so>
```

OpenXR/OpenGL ES video-stack feasibility example:

```powershell
powershell -ExecutionPolicy Bypass `
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
