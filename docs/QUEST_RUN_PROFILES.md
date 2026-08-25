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

Machine-local build prerequisites use profile environment variables mapped to
portable binding IDs. A separate hash-pinned
`rusty.morphospace.local_quest_build_environment.v1` file resolves those IDs
to files or directories; Git-backed directories can require an exact clean
revision and tree. The receipt records only the variable, binding ID, kind, and
Git identity. A nonzero build retains both streams and a typed failure receipt.

An optional `preflight.source_composition` adds an exact lock for the host
source revision/tree and named external source bindings such as the Quest File
Manager source. Each external lock names the local binding ID and its expected
clean revision/tree; the local binding file supplies the private path. This is
host-only composition evidence, not permission to inspect, deploy, invoke ADB,
or otherwise act in the external owner's lane. The later single-APK terminal
proof remains one digest-bound `single-base-apk` result, and any QFM-specific
inspection remains QFM-owned.

The build profile removes recurring Gradle/PowerShell command reconstruction.
The run request does not contain an arbitrary device command. A private Hostess
provider map resolves the hash-pinned File Manager deployment wrapper, a complete
provider distribution closure (not a lone executable), File Manager provider
config, and verified diagnostic adapter. Hostess plans or runs
only those adapters, retains foreign receipts by path and SHA-256, and resumes
only completed hash-valid stages.

## Host-only executable preflight

`Invoke-QuestBuildProfile.ps1 -Mode Preflight` is an advisory producer for the
same reviewed build-profile resolution path used by `-Mode Build`. It resolves
the exact child executable and argv, profile/executable/source/lock and
manifest-relative file hashes, declared repository-owned toolchain files and
targets, package/application/signer expectations, explicit child-environment
projection, and warm/Candidate output/collision policy. It emits one
`execution_preflight_observation.v1`-bound terminal JSON document to stdout in
seconds; it does not build, mutate source, reserve a resource, call ADB, touch
a device, or publish a file.

Preflight terminal status is only `passed`, `contradiction`, or `incomplete`.
The companion owner-local
`rusty.morphospace.quest_build_terminal_result.v1` carries the exact observation
identity/hash and a deterministic `binding_sha256`; it does not create a
WorkUnit candidate fingerprint. The owning workflow may associate its existing
Inspect-created candidate fingerprint only after an explicit binding check.
Build paths add `failed`, `timed_out`, and `cancelled` as applicable, retain
raw stdout/stderr as separately digest-bound byte evidence, and publish at most
one atomic terminal result. The terminal result records the explicit timeout,
typed child-process outcome/cancellation/process-tree termination evidence, and
the digest of the deliberately constructed child environment. If profile or
execution resolution fails before a child environment exists, that digest is
explicitly null with count zero and the child is `not-started`. Child
environments otherwise begin empty and receive only reviewed projection values
plus wrapper-derived values, so inherited control variables such as `GIT_PAGER`
cannot affect execution. A profile that prohibits an ambient `GIT_PAGER`
therefore fails closed at preflight rather than silently sanitizing the
contradiction away.

Candidate output requires an observable clean source tree and
`content-addressed` collision policy. Its APK `relative_path` contains exactly
one `{content_sha256}` marker, which the wrapper replaces with the deterministic
preflight binding digest before it starts the child; the derived effective path
and derivation digest are retained in the terminal receipt. Warm output remains
a deliberately separate mutable lane. `created_at` remains receipt telemetry;
`content_sha256` is the stable semantic observation identity and excludes that
timestamp, while the terminal observation hash still binds the complete
timestamped receipt. This observation is not an admission gate: a later locked
trust-root change may consume it only after adopted-main evidence and the
existing external validation-authority procedure.

Start from
[`quest-build-profile.example.json`](../templates/quest-build-profile.example.json)
and run the non-mutating observation locally:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-QuestBuildProfile.ps1 `
  -Mode Preflight `
  -ProfilePath <reviewed-profile.json> `
  -ProfileSha256 <profile-sha256> `
  -SourceRoot <app-source-root>
```

The Work Environment consumer fixture targets QFM
`app_runtime_observation.v5` plus
`android_global_focus_observation.v1`, plus the separate read-only
`apk_permission_observation.v1`, while retaining named legacy-v3 and legacy-v4
adapters. It preserves installed identity, process, task/top-resumed, global
Android focus, package permission declarations, reported grant bits, and app-op
modes as separate fact families. Its app-evidence family is
always explicit `unknown` until an app-owned receipt arrives: PID/process,
top-resumed, or raw focus—including a brief app-focused frame followed by
Meta `FocusPlaceholderActivity`—cannot become application/OpenXR readiness.
Permission observation likewise cannot establish permission policy, grantability,
feature use, readiness, or wearer visibility. Unknown and unavailable provider
facts remain explicit rather than being silently converted to success or failure.
