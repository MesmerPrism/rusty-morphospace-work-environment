# Setup Overview

This guide assumes a contributor starts from a clean workstation and wants to
build Rusty Morphospace apps or public examples.

## 1. Clone This Repo

```powershell
git clone https://github.com/MesmerPrism/rusty-morphospace-work-environment.git <workspace-root>\rusty-morphospace-work-environment
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
- PowerShell 7.6 LTS or newer (`pwsh`)
- Rustup and Cargo
- Python 3.11 or newer
- ripgrep
- Android SDK command-line tools and platform-tools
- Android NDK for native Quest builds
- JDK 17 or newer
- Node.js and npm/npx for optional Meta tooling

Windows PowerShell 5.1 is not the workflow host. It remains installed alongside
PowerShell 7 and may run the bootstrap detector only:

```powershell
pwsh -NoProfile -File .\scripts\Test-PowerShellHost.ps1
```

If `pwsh` is missing on Windows, install the current LTS release with
`winget install --id Microsoft.PowerShell --source winget`, open `pwsh`, and
rerun the detector.

Then run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkEnvironment.ps1 `
  -ConfigPath .\local\local.paths.json `
  -Profile Core `
  -Strict
```

Use `-Profile Quest` only when Android/Quest build dependencies are in scope.
Use `-SelfTest -Tier Quick` to verify the repo's portable contracts without a
device; `Standard` adds work-unit automation and `Deep` adds authority tests.

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

Read [Local Skill Bootstrap](LOCAL_SKILL_BOOTSTRAP.md) for new installs,
existing unmanaged directories, provenance, backups, and updates.

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
```

If your agent uses a different skill location, pass that directory with
`-TargetRoot`. Verify after installation with `-Action Verify`. Install never
overwrites an existing directory; updates require `-Action Update -Execute` and
create a timestamped backup.

## 5. Scaffold A Project Workflow

For an application that will compose reusable Morphospace modules, start with
a dry run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-ProjectWorkspace.ps1 `
  -ProjectRoot <project-root> `
  -ProjectId <project-id>
```

Re-run with `-Execute` to create a no-overwrite `morphospace/` directory in
the project. Read [Project Workspace Protocol](PROJECT_WORKSPACE_PROTOCOL.md)
before filling its module list or activating features.

## 6. Build A Public APK Example

From a cloned Rusty XR repo:

```powershell
rustup target add aarch64-linux-android
pwsh -ExecutionPolicy Bypass `
  -File .\examples\quest-minimal-apk\tools\Build-QuestMinimalApk.ps1
```

Immersive OpenXR/Vulkan examples also need a Quest-compatible OpenXR loader:

```powershell
pwsh -ExecutionPolicy Bypass `
  -File .\examples\quest-composite-layer-apk\tools\Build-QuestCompositeLayerApk.ps1 `
  -AndroidSdkRoot <android-sdk-root> `
  -AndroidNdkRoot <android-ndk-root> `
  -JdkRoot <jdk-root> `
  -OpenXrLoaderPath <openxr-loader-so>
```

Generated APKs stay in ignored build folders.

## 7. Install And Launch On Quest

Use [Quest APK Workflow](QUEST_APK_WORKFLOW.md). The short form is:

```powershell
adb -s <quest-serial> install -r -d -g <path-to.apk>
adb -s <quest-serial> shell am start -W -n <package>/<activity>
adb -s <quest-serial> logcat -d -v threadtime > <out-dir>\logcat.txt
```

Live headset operations should follow the public Meta Quest workflow. Keep
serials, screenshots, logcat, and device run artifacts out of this repo.
