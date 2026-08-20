# Dependency Matrix

This matrix names required tool categories and verification commands. It does
not pin global versions. Source repos may add tighter version requirements.

## Core

| Tool | Required for | Verify |
| --- | --- | --- |
| Git | source control, submodules, tags | `git --version` |
| PowerShell 7.6 LTS+ | authoritative portable workflow host (`pwsh`); Windows PowerShell 5.1 is bootstrap detection only | `pwsh -NoProfile -File ./scripts/Test-PowerShellHost.ps1` |
| Rust toolchain (Cargo ships with Rust) | Rust workspaces and Android target setup | `rustc --version`; `cargo --version`; `rustup --version` |
| Python 3.11+ | schema, docs, graph, and validation helpers | `python --version` |
| ripgrep | fast source and docs search | `rg --version` |

## Android And Quest

| Tool | Required for | Verify |
| --- | --- | --- |
| Android SDK command-line tools | SDK manager, platform install | `sdkmanager --version` |
| Android platform-tools | ADB, device install/launch/logcat | `adb version` |
| Android build-tools | AAPT2, D8, zipalign, apksigner | `<android-sdk-root>\build-tools\...` exists |
| Android platform package | `android.jar` for Java compilation | `<android-sdk-root>\platforms\android-<api>\android.jar` exists |
| Android NDK | `aarch64-linux-android` native builds | NDK `toolchains\llvm` exists |
| JDK 17+ | Java compile, signing, Android tooling | `java -version`; `javac -version` |
| Quest-compatible OpenXR loader | immersive OpenXR APK examples | `<openxr-loader-so>` exists |
| Node.js/npm/npx | optional Meta VR CLI route | `node --version`; `npx --version` |

## Rust Targets

Install the Quest Android Rust target:

```powershell
rustup target add aarch64-linux-android
```

Optional probes may need:

```powershell
rustup target add x86_64-pc-windows-msvc
```

## Makepad

Makepad Android packaging should use a host-matched Android SDK and the
selected Makepad checkout or fork. Do not fabricate SDK shadow folders to work
around stale packager assumptions. Select or update a packager that resolves
installed build-tools, platform, Java, NDK prebuilt, and host executable names
from the supplied SDK path.

Typical command shape:

```powershell
cargo makepad android `
  --abi=aarch64 `
  --variant=quest `
  --sdk-path=<android-sdk-root> `
  --package-name=<public-example-package> `
  --app-label="<app-label>" `
  build -p <makepad-app-package> --release
```

## Termux Sidecar

For the public lab route on a Quest headset, install Termux-family components
from their upstream projects and follow their licenses:

- Termux
- Termux:X11
- Termux:Boot, only when a runbook explicitly needs boot status probes
- Proot-Distro, only for Linux sidecar experiments

Inside Termux, typical packages for the on-device APK loop are:

```sh
pkg update
pkg install android-tools openjdk-17 aapt2 d8 apksigner rust cmake ninja clang make git
```

Package availability can vary. Record exact versions in private run evidence,
not in public committed docs.

## Environment Variables

Preferred portable variable names:

| Variable | Meaning |
| --- | --- |
| `RUSTY_MORPHOSPACE_WORKSPACE` | root containing this repo and source repos |
| `RUSTY_MORPHOSPACE_REPOS` | root containing source checkouts |
| `RUSTY_XR_ANDROID_SDK_ROOT` | Android SDK root |
| `RUSTY_XR_ANDROID_NDK_ROOT` | Android NDK root |
| `RUSTY_XR_ANDROID_JDK_ROOT` | selected JDK root |
| `RUSTY_XR_OPENXR_LOADER_QUEST` | Quest-compatible `libopenxr_loader.so` |
| `RUSTY_QUEST_MAKEPAD_SOURCE_ROOT` | selected Makepad checkout |
| `RUSTY_MORPHOSPACE_ARTIFACTS` | local ignored artifact root |

See [local.env.example.ps1](../templates/local.env.example.ps1).

See [Rust Toolchain Policy](RUST_TOOLCHAIN_POLICY.md) for the observed Rust
1.97.1 baseline and non-authorizing advisory cadence.
