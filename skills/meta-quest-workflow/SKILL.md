# Meta Quest Workflow

Use this skill before touching a Quest headset, ADB, APK install/launch,
logcat, screenshots, screenrecord, Perfetto, Wi-Fi ADB, Meta VR CLI, Meta
Horizon MCP, or Quest runtime validation.

This template is a Morphospace router. For detailed portable device-operation
docs and scripts, use the public `meta-quest-agent-workflow` repository.

## First Read

In this work-environment repo:

1. `docs/QUEST_APK_WORKFLOW.md`
2. `docs/TERMUX_SIDECAR_LAB.md`
3. `docs/PUBLIC_PRIVATE_BOUNDARY.md`

In the public Meta Quest workflow repo:

1. `README.md`
2. `docs/adb-basics.md`
3. `docs/apk-install-launch.md`
4. `docs/artifact-and-evidence-discipline.md`
5. `docs/quest-signal-patterns.md`
6. `docs/termux-linux-sidecars.md`, if Termux is involved

## Core Rules

- Use serial-scoped ADB: `adb -s <quest-serial> ...`.
- Prefer read-only probes before install, launch, permission grants, file
  mutation, settings changes, port forwarding, or captures.
- Record provider, command goal, foreground before/after, artifact types, and
  cleanup state.
- Do not treat screenshots, casting, screenrecord, or MediaProjection as raw
  camera access.
- Do not treat ADB synthetic input as OpenXR controller parity.
- Do not treat Termux as Android shell authority unless an already authorized
  ADB gate reports `uid=2000(shell)`.
- Keep raw device evidence private unless a public redaction gate exists.

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
- running long APK builds or Perfetto captures on shared devices;
- using package identities or artifacts from private apps in public docs.
