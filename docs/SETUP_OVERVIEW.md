# Setup Overview

This guide assumes a contributor starts from a clean workstation and wants to
build Rusty Morphospace apps or public examples.

## 1. Clone This Repo

```powershell
git clone <work-environment-repo-url> <workspace-root>\rusty-morphospace-work-environment
cd <workspace-root>\rusty-morphospace-work-environment
```

Keep machine-specific values out of git:

```powershell
New-Item -ItemType Directory -Force .\local | Out-Null
Copy-Item .\templates\local.paths.example.json .\local\local.paths.json
```

Edit `local\local.paths.json` for your machine.

## 2. Install Core Tools

See [Dependency Matrix](DEPENDENCY_MATRIX.md). A practical minimum is:

- Git
- PowerShell 7 or Windows PowerShell 5.1
- Rustup and Cargo
- Python 3.11 or newer
- ripgrep
- Android SDK command-line tools and platform-tools
- Android NDK for native Quest builds
- JDK 17 or newer
- Node.js and npm/npx for optional Meta tooling

Then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkEnvironment.ps1 `
  -ConfigPath .\local\local.paths.json `
  -Strict
```

Use `-SelfTest` when you only want to verify that the repo's manifests and
scripts parse.

## 3. Clone Source Repos

The work environment repo does not force one directory layout. A portable
layout is:

```text
<workspace-root>/
  rusty-morphospace-work-environment/
  repos/
    Rusty-XR/
    Rusty-XR-Companion-Apps/
    meta-quest-agent-workflow/
    quest-termux-lab/
    rusty-manifold/
    rusty-lattice/
    rusty-quest/
    makepad-morphospace/
```

Only clone the repos needed for the current task. Use [Repo Lanes](REPO_LANES.md)
to decide where a change belongs.

## 4. Install Local Skills

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot <codex-skills-root> `
  -Execute
```

If your agent uses a different skill location, pass that directory with
`-TargetRoot`. The installer is dry-run by default and refuses to overwrite an
existing skill directory.

## 5. Build A Public APK Example

From a cloned Rusty XR repo:

```powershell
rustup target add aarch64-linux-android
powershell -ExecutionPolicy Bypass `
  -File .\examples\quest-minimal-apk\tools\Build-QuestMinimalApk.ps1
```

Immersive OpenXR/Vulkan examples also need a Quest-compatible OpenXR loader:

```powershell
powershell -ExecutionPolicy Bypass `
  -File .\examples\quest-composite-layer-apk\tools\Build-QuestCompositeLayerApk.ps1 `
  -AndroidSdkRoot <android-sdk-root> `
  -AndroidNdkRoot <android-ndk-root> `
  -JdkRoot <jdk-root> `
  -OpenXrLoaderPath <openxr-loader-so>
```

Generated APKs stay in ignored build folders.

## 6. Install And Launch On Quest

Use [Quest APK Workflow](QUEST_APK_WORKFLOW.md). The short form is:

```powershell
adb -s <quest-serial> install -r -d -g <path-to.apk>
adb -s <quest-serial> shell am start -W -n <package>/<activity>
adb -s <quest-serial> logcat -d -v threadtime > <out-dir>\logcat.txt
```

Live headset operations should follow the public Meta Quest workflow. Keep
serials, screenshots, logcat, and device run artifacts out of this repo.
