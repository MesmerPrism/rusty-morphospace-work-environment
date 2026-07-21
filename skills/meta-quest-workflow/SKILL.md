---
name: meta-quest-workflow
description: 'Use for connected Meta Quest work: APK install, launch, and validation; serial-scoped ADB; Meta VR CLI or hzdb checks; screenshots, logcat, and Perfetto; Wi-Fi ADB; Rusty Morphospace headset smoke tests; and Quest toolchain routing.'
---

# Meta Quest Workflow

Use this skill before touching a Quest headset, ADB, APK install/launch,
logcat, screenshots, screenrecord, Perfetto, Wi-Fi ADB, Meta VR CLI, Meta
Horizon MCP, or Quest runtime validation.

This template is a Morphospace router. For detailed portable device-operation
docs and scripts, use the public `meta-quest-agent-workflow` repository.

## Resolve The Local Work Environment

When installed by `Install-LocalSkills.ps1`, read
`references/local-work-environment.json` before following work-environment doc
paths. It binds the exact local clone, source commit/release, dirty-source state,
and docs root. If absent, use an explicitly configured
`RUSTY_MORPHOSPACE_WORK_ENVIRONMENT` or ask for the clone; never guess paths.

## First Read

In this work-environment repo:

1. `docs/QUEST_APK_WORKFLOW.md`
2. `docs/PROJECT_ISOLATION.md`
3. `docs/TERMUX_SIDECAR_LAB.md`
4. `docs/PUBLIC_PRIVATE_BOUNDARY.md`
5. `docs/INSTRUCTION_SYNCHRONIZATION.md`, when device or evidence policy changes

In the public Meta Quest workflow repo:

1. `README.md`
2. `docs/adb-basics.md`
3. `docs/apk-install-launch.md`
4. `docs/managed-device-store-apps.md`, when organization-managed modes,
   consumer or managed Store apps, paid entitlements, or launcher cleanup is
   involved
5. `docs/artifact-and-evidence-discipline.md`
6. `docs/quest-signal-patterns.md`
7. `docs/accessibility-foreground-watchdogs.md`, when foreground monitoring,
   Meta Home transitions, or special Accessibility enablement is involved
8. `docs/termux-linux-sidecars.md`, if Termux is involved

## Core Rules

- Use serial-scoped ADB: `adb -s <quest-serial> ...`.
- Treat the default ADB daemon as shared infrastructure. When Agent Board
  coordination is active, routine discovery and serial-scoped commands do not
  take a global ADB lease. Reserve the exact `quest:<serial>` for exclusive
  headset work and `adb-server:lifecycle` only for disruptive daemon or
  transport operations.
- Prefer read-only probes before install, launch, permission grants, file
  mutation, settings changes, port forwarding, or captures.
- Record provider, command goal, foreground before/after, artifact types, and
  cleanup state.
- Do not treat screenshots, casting, screenrecord, or MediaProjection as raw
  camera access.
- Do not treat ADB synthetic input as OpenXR controller parity.
- For organization-managed Store validation, identify Individual versus Shared
  Mode and the active Android user/profile. Individual Mode can expose the
  consumer Store when policy permits; Shared Mode uses a separate managed
  catalog. Paid purchases, Store PINs, payment, and terms remain attended
  account-holder actions and must not be automated.
- Distinguish a fresh Android task from a fresh process. Background tasks are
  normal OS-managed state; do not add arbitrary app force-stop authority merely
  for launcher cleanup.
- Treat an Accessibility foreground watchdog as a user-enabled diagnostic
  capability, not HOME interception or kiosk authority. Disable UI-content
  retrieval, group one Meta Home event burst into one invocation, allow late
  shell tails to request refocus without double-counting escape gestures, and
  revalidate exact signals/background launch behavior after Horizon updates.
- Do not treat Termux as Android shell authority unless an already authorized
  ADB gate reports `uid=2000(shell)`.
- Keep raw device evidence private unless a public redaction gate exists.
- When several projects share one headset, require distinct package/client,
  build-output, property, and staging identities. Validate a hashed run capsule
  before install, serialize mutations per serial, snapshot and clear the
  complete app property manifest, and restore exact prior values in `finally`.
  Stop only the target package; do not force-stop or clean unrelated apps as
  generic preflight.
- Validate the shared particle adapter per consumer with serial-scoped ADB.
  Require each effective `channel=particle-adapter` marker, fold private logs
  with `rusty-quest/tools/Test-QuestParticleAdapterEvidence.ps1`, require
  high-rate JSON false and backend payload absent, then stop both packages and
  clear only run-owned adapter profile state.
- For shared hand-adapter promotion, use the native hand-lab app build on one
  serial and the Spatial live-hand bridge smoke on the other. Require accepted
  `channel=hand-adapter` markers, zero package fatals, and evidence folded
  through `rusty-quest/tools/Test-QuestHandAdapterEvidence.ps1`; then stop both
  packages and restore the run-owned native adapter property to `false`.
- For signature-scoped cross-app broker admission, build the broker first so
  its certificate fingerprint and arm64 JNI library enter the product, then
  build one same-keystore client and one separately signed client. On every
  serial require the authorized issue/use/replay/revoke/post-revoke marker,
  unauthorized `signature-permission` denial, zero package fatals, and
  force-stop plus uninstall cleanup. Raw device evidence and generated keys
  stay private; Manifold remains grant/token/replay/revocation authority.
- For two independent product-app consumers, build the broker and both apps
  with one signing identity, then run the repo's multi-app suite with exactly
  two explicit serials. Require distinct Android app ids, client ids, feature
  locks, marker namespaces, grants, and app-local capabilities while both apps
  use only the accepted peer/media contracts. Reject cross-markers, authority
  revision reset on rebind, default/property bleed, fatals, incomplete generic
  evidence folding, or incomplete force-stop/uninstall cleanup.
- Generic media source/build conformance is not a headset gate. Full media
  broker builds require the exact generated media-session binding. For the
  two-Quest lifecycle, command acceptance remains
  `platform_effect_completed=false` until each app's exact lock/lease consumes
  a prepared action, seven owner-issued provider-state/readback completions
  apply in Rust, and fresh
  hash/epoch/bytes/frames/render, death/recovery, no-bleed, fatal, and cleanup
  evidence passes on both explicit serials. Package the real app feature-lock
  fingerprint/SHA and separate accepted descriptor/sink; never relabel a
  display/Hostess sink as OpenXR or Spatial render adoption.
- For product Wi-Fi Direct, require two explicit serials, temporary
  credentialed topology, honest Android `Network` availability, Rust-owned
  explicit `p2p0` bind and bounded non-media exchange, inactive cleanup, zero
  package/system fatals, and task-authorized package removal. A missing public
  Android `Network` must not be converted into a fake handle or Android socket
  authority.
- For BLE-to-product-topology validation, require the live two-role BLE pair
  with authenticated reconnects, project it to Manifold, then prove
  unauthenticated, stale-after-revocation, and revoked decisions remain
  non-grouped. Only a fresh accepted revision may initialize Wi-Fi P2P and run
  the bounded Rust-socket exchange; BLE never carries media or mutates topology.
- For configured N-peer proof with two physical Quests, require a fresh BLE
  role swap/reconnect between the live peers, then fold one sanitized configured
  peer through Manifold. Require three members, only the authenticated live
  pair as a direct candidate, replay/split-brain/advisory-media rejection,
  expiry/revocation, zero fatals, stable state, and package cleanup. Explicitly
  clear and record any Guardian launch blocker before rerun.
- For admission death/recovery, namespace requests per client process, bind a
  same-authority rebind to the current revision, and explicitly restart the
  broker into a fresh epoch after provider `force-stop`. If 6DoF launch is
  unavailable, use dedicated 2D admission clients rather than bypassing
  Guardian. Wait for the signature grant, retain failed attempts, require zero
  bounded fatals, and uninstall all test packages on both explicit serials.

## Install And Launch Shape

```powershell
adb -s <quest-serial> install -r -d -g <path-to.apk>
adb -s <quest-serial> shell am start -W -n <package>/<activity>
adb -s <quest-serial> logcat -d -v threadtime > <out-dir>\logcat.txt
```

## Stop Rules

Stop and ask for explicit operator approval before:

- resetting the ADB server;
- changing Wi-Fi ADB state;
- uninstalling or clearing apps;
- deleting files from a device;
- changing proximity, power, or keep-awake policy;
- choosing or completing a paid Store transaction, entering a Store PIN or
  payment, or accepting purchase terms on the user's behalf;
- running long APK builds or Perfetto captures on shared devices;
- using package identities or artifacts from private apps in public docs.

When durable device, ADB, APK, QCL, sidecar, signal, capture, or evidence rules
change, synchronize this router, the touched repo `AGENTS.md`, and the nearest
README/runbook entrypoint in the same iteration unit. Keep operational recipes
in the public device-workflow docs rather than expanding this router.
