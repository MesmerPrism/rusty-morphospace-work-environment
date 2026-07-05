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

## Validation

Before committing, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkEnvironment.ps1 -SelfTest
git diff --check
```

If docs or manifests change, also parse JSON files:

```powershell
Get-ChildItem .\manifests,.\templates -Filter *.json -File |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
```
