# Exact Quest run profiles

A regular iteration now has two portable, non-authoritative inputs:

- a reviewed `rusty.morphospace.quest_build_profile.v1` in the owning app
repository, containing the fixed build vector and expected single-base APK;
- a private `rusty.morphospace.quest_run_request.v1`, binding the resulting APK
  bytes, exact serial, 2D/XR/process observation policy, app-owned log oracle,
and named diagnostic recipes.

An app can name a repository-relative build wrapper or the portable `gradle`
tool id. The latter requires a separate private absolute `ToolPath` and
`ToolSha256`; the resolved `gradle.bat`/`gradle.exe` hash is recorded in the
build receipt. This keeps machine paths out of the portable profile without
silently trusting whichever Gradle happens to be first on `PATH`.

The build profile removes recurring Gradle/PowerShell command reconstruction.
The run request does not contain an arbitrary device command. A private Hostess
provider map resolves the hash-pinned File Manager deployment wrapper, File
Manager provider config, and verified diagnostic adapter. Hostess plans or runs
only those adapters, retains foreign receipts by path and SHA-256, and resumes
only completed hash-valid stages.

Use `ImmersiveXr` when an app can remain top-resumed while the legacy
foreground projection is false. This policy still rejects a retained Guardian
or sensor-lock component. `Android2d` requires both legacy foreground and
top-resumed facts. `ProcessAlive` is diagnostic-only and proves no visible or
effective app state. The app oracle remains the authority for effective app
readiness.
