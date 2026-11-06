# Exact Quest run profiles

A regular iteration now has two portable, non-authoritative inputs:

- a reviewed `rusty.morphospace.quest_build_profile.v1` in the owning app
repository, containing the fixed build vector and expected artifact kind;
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

The closed artifact kinds are `single-base-apk` (the existing `.apk` build)
and `jvm-preflight-result` (one `.json` host phase result). Both use the same
profile, context, environment projection, child execution, stream capture and
post-exit artifact binding. A successful terminal result retains the selected
kind and the file's exact path, SHA-256 and size. A typed JVM phase JSON cannot
satisfy `single-base-apk`; APK bytes cannot satisfy `jvm-preflight-result`.
Single-base APK transport keeps its existing behavior and host fixtures;
inspection remains a separate APK-owner operation.

The phase result uses `rusty.quest.spatial_camera_panel.jvm_preflight_result.v1`,
`status=phase-complete`, `build_stage=JvmPreflight`, `apk_produced=false` and
`runtime_authority=false`. It retains product/application/build identity, the
original `android_jvm_compilation` summary, and references to source composition,
Android component inventory/JVM inputs/compilation and build phase receipts.
The public builder writes `OutDir/jvm-preflight-result.json`; a private wrapper
can copy those exact bytes to its own declared output. The runner discriminates
this shape and binds its bytes; referenced component semantics stay with the
producer. This host result supplies no APK, inspect/install, runtime or release
capsule completion evidence. `-Mode Preflight` remains the runner's separate
advisory pre-dispatch operation.

The build profile removes recurring Gradle/PowerShell command reconstruction.
The run request does not contain an arbitrary device command. A private Hostess
provider map resolves the hash-pinned File Manager deployment wrapper, a complete
provider distribution closure (not a lone executable), File Manager provider
config, and verified diagnostic adapter. Hostess plans or runs
only those adapters, retains foreign receipts by path and SHA-256, and resumes
only completed hash-valid stages.

## Retained build originals

New callers can explicitly select `-WaitPolicy Retained` with a positive
`-EstimatedWarningSeconds`. The estimate emits diagnostics only. The same
once-issued child and both output readers remain owned until actual parent
exit, reap and both stream completions, including descendant-held pipes.
Warning publication failure never cancels or repeats the build. Explicit
console cancellation remains a separate action and still settles that original.

This mode emits `rusty.morphospace.quest_build_terminal_result.v2`. It records
the selected policy, actual process/EOF facts, independently drained and stored
raw bytes, capture errors, and attempted/failed warning publication. A raw sink
failure continues draining the original producer and reports failure after
settlement; partial raw evidence remains retained. A passed result requires
exit zero, actual reap, both EOFs and complete authenticated raw capture.
Parent reap and output EOF do not assert absence of arbitrary descendant work.

The default `Bounded` compatibility mode retains the explicit `TimeoutSeconds`
deadline and v1 result. Its deadline is a cancellation policy, not a progress
estimate. New ongoing preparation callers should deliberately select retained
mode and qualify its v2 consumer. Source, signer, profile, artifact and output
collision checks remain unchanged. Neither mode grants device authorization.
The owning controls are `Test-QuestBuildProfile.ps1` and its causal retained
original corpus `Test-QuestBuildRetainedOriginal.ps1`.
The corpus uses the declared core Python dependency for a producer that
explicitly inherits both output pipes into a real descendant. It verifies a
new warning after the observed parent exits, then releases the descendant and
checks both large byte streams and their late tails. It also exercises raw and
warning sink faults, actual nonzero exit, requested cancellation, and the public
preflight/build boundary. Its four-byte artifact is a host fixture, not an APK
or device validation result.

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

While an owner build profile is running, its optional read-only progress
observer can inspect the base receipt path supplied to `-Mode Build`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Inspect-QuestBuildProgress.ps1 `
  -BaseReceiptPath <build-receipt.json>
```

The observer reads at most the final 8 KiB of each uniquely selected active
stream or finalized stream and reports absent, ambiguous, and unreadable states
explicitly. Stream lines may contain private build output; retain its JSON in
the task's private evidence location. A milestone, readable stream, or visible
receipt path does not prove that the build passed. Use the terminal result and
its bound stream hashes for the build outcome. The observer starts no build or
device operation and does not change either stream or receipt.

The Work Environment consumer fixture targets QFM
`app_runtime_observation.v5` plus
`android_global_focus_observation.v1`, plus the separate read-only
`apk_permission_observation.v1`, while retaining named legacy-v3 and legacy-v4
adapters. It preserves installed identity, process, task/top-resumed, global
Android focus, package permission declarations, reported grant bits, and app-op
modes as separate fact families. Its app-evidence family is
always explicit `unknown` until an app-owned receipt arrives: PID/process,
top-resumed, or raw focusâ€”including a brief app-focused frame followed by
Meta `FocusPlaceholderActivity`â€”cannot become application/OpenXR readiness.
Permission observation likewise cannot establish permission policy, grantability,
feature use, readiness, or wearer visibility. Unknown and unavailable provider
facts remain explicit rather than being silently converted to success or failure.

## Selected build context and developer environment

Use one ignored `local_quest_build_context.v1` document for the declared
nonsecret environment and exact scalar Cargo, Rustc, Rustup, PowerShell and Git
paths/hashes. `Invoke-QuestBuildProfile.ps1` accepts the paired
`-BuildContextPath` and `-BuildContextSha256` inputs with the existing Preflight
and Build modes. A direct toolchain executable remains usable when Rustup proxy
siblings are also on PATH: explicit selection bypasses ambient discovery.
When selected Git is declared, the first actual PATH Application for bare Git
consumers must resolve to that exact canonical selection; a different earlier
Git refuses. Later PATH Git entries do not replace explicit selection.
Without a context, compatibility discovery preserves ordinary PATH precedence
and returns the first PowerShell or Rustup Application as one scalar. It does
not authenticate that choice as an explicit selected tool. Context selections
retain their exact path/hash, canonical path and compiler/target checks.

The shared `scripts/lib/MorphospaceQuestBuildEnvironment.psm1` exports
`Resolve-MorphospaceQuestBuildContext` and
`Invoke-MorphospaceQuestBuildEnvironment`. The app resolves tools and declared
targets before native exports, then invokes its existing preparation and build
code in the resolved environment. The complete profile preflight still runs
after generated inputs exist. An input-only source/workspace preflight does not
prove tool, signer, platform or build readiness. Source/admission, native writer
and cache-origin guards remain with their existing owners.

The resolver probes the exact selected tools under the same effective
in-memory environment returned to the synchronous action. It derives RUSTC and
RUSTUP_TOOLCHAIN, refuses contradictory explicit bindings, and compares the
selected compiler version/sysroot with the declared Rustup toolchain before
accepting an installed target. It never installs a target or updates a tool.
Only explicitly reviewed passthrough names absent from the literal context are
imported. Signing passwords and a transient application media key use that
existing in-memory overlay; they must never be serialized into the context or
printed. Public environment evidence contains names, origins and presence only.
The resolved object contains sensitive in-memory values and must not be serialized or logged.

Windows host exports also require the actual developer environment, including
INCLUDE, LIB, LIBPATH, VCINSTALLDIR, VCTOOLSINSTALLDIR, WINDOWSSDKDIR and
UNIVERSALCRTSDKDIR plus existing VS/SDK PATH directories. Select and hash-check
the installed Microsoft's `Launch-VsDevShell.ps1` in a preparation PowerShell
session, invoke its documented `-Arch amd64 -HostArch amd64
-SkipAutomaticLocation` route, and author the context there with the same WEF
module. This is one data-authoring/refresh operation, not a required runtime
wrapper. Keep the selected Microsoft script identity and actual preparation
result in ignored evidence; do not discover or provision Visual Studio from the
build runner. The app-owned early prerequisite check must confirm actual cl,
link and rc identities and the declared VS/SDK roots before native export.

```powershell
Import-Module ./scripts/lib/MorphospaceQuestBuildEnvironment.psm1
# In the explicitly selected developer session; all values below are local.
$authored = New-MorphospaceQuestBuildContext `
  -SourceRoot <owning-source-root> -OutputPath <ignored-new-context.json> `
  -EnvironmentVariableNames @('PATH','SYSTEMROOT','SYSTEMDRIVE','WINDIR',
    'COMSPEC','PATHEXT','TEMP','TMP','USERPROFILE','HOME','RUSTUP_HOME',
    'CARGO_HOME','INCLUDE','LIB','LIBPATH','VCINSTALLDIR','VCTOOLSINSTALLDIR',
    'WINDOWSSDKDIR','UNIVERSALCRTSDKDIR') `
  -ToolPaths @{cargo=<selected-cargo>;rustc=<selected-rustc>;
    rustup=<selected-rustup>;pwsh=<selected-pwsh>;git=<selected-git>} `
  -RustToolchainChannel <declared-channel> `
  -RequiredTargets @('aarch64-linux-android')
```

The author checks that its create-new output is Git-ignored, hashes the explicit
tools, and validates the captured data. It captures only named nonsecret
variables, never the whole ambient environment. `EnvironmentOverrides` permits
explicit reviewed values such as the complete existing-directory PATH and
app-owned Java/Android roots. A refused authored document remains evidence and
is never silently overwritten or deleted. Refresh into a fresh output when
tools or the developer environment change. Future builds consume the same
supported context/profile path directly, without rebuilding a task wrapper or
creating tool aliases. `templates/quest-build-context.example.json` contains
placeholders only and must not be executed before local resolution.

Selected tool and context aliases are resolved to canonical leaf paths before
use, including ordinary Linux executable symlinks. Dispatch uses that canonical
path. Reparse changes at the held boundary refuse. Windows read sharing excludes
byte replacement while the context/tool/source holds are live. Other hosts do
not acquire Windows sharing semantics; byte/path checks and their concurrency
limits remain explicit. Resolved environment/tool map mutation refuses before
Action. Synchronous scopes serialize process environment changes, restore every
original variable in finally, and allow no background work inside that scope.
For subprocesses use the existing retained-process primitive with explicit
EnvironmentValues: actual exit, reap, both EOFs, raw hashes and persisted final
caller proof are still required, with no automatic retry or provisioning. A
successful context or host fixture never establishes an APK or device result.


### Presence-only environment observation

All persisted environment rows use names, origins and presence only;
`value_sha256`, resolved `EnvironmentSha256` and terminal
`child_environment_sha256` are null. This default applies to base values,
transient overlays, profile bindings and legacy passthrough, so a caller cannot
accidentally disclose a password or media-key fingerprint by omitting a
sensitivity declaration. The nonsecret context file retains its raw artifact
hash; credentials must never be authored into that file or arguments.

`quest-build.environment-observation-policy = presence-only-v1` identifies this
policy. Invocation/output bindings and preflight observation hashes cover the
sanitized metadata plus their existing profile/source/tool/execution inputs;
they do not attest exact credential values or authorize artifact reuse across
different credentials. No credential-derived digest is substituted under a
new metadata-hash name.

The module keeps its exact resolved-map mutation fingerprint and nested-scope
comparison private in memory. Changes to environment values, public context
metadata, tools or evidence still refuse before Action; canonical source/tool/
context holds and finally rechecks, the mutex, compatible nesting, contradictory
nesting refusal and full parent restoration remain required. The runner guards
its private final child map immediately before dispatch. Public nulls are not
compared as an exact-environment proof.

Original child streams, exit/reap/both EOF and permitted whole-artifact integrity
hashes retain their existing raw provenance. This policy does not rewrite raw
streams or make a child that prints credentials safe. Owners must keep secrets
out of command arguments, logs and artifacts. Older evidence remains immutable
and is not relabeled as presence-only proof.
