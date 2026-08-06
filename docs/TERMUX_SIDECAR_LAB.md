# Termux Sidecar Lab

Termux is useful for Quest lab workflows, but it remains a normal Android app.
This repo documents the boundary so Morphospace developers do not accidentally
turn a sidecar into hidden shell or runtime authority.

## What Termux Can Prove

- A Quest can run a Linux-like userland sidecar.
- Termux can host scripts, small services, local dashboards, Termux:X11,
  Proot, and VNC-style lab surfaces.
- After a user-approved or externally enabled Wi-Fi ADB route exists, the
  Termux `adb` client can connect to loopback and use that already authorized
  shell lease.
- A source-only smoke APK can be built, signed, installed, and launched from
  Termux when the loopback ADB shell gate passes.
- Termux can be a bounded typed client of a custom OpenXR API layer that was
  already packaged and activated by the foreground development APK.

## What Termux Does Not Prove

- No root, managed-device, HOME replacement, kiosk, or hidden boot authority.
- No ADB authorization bypass.
- No guaranteed ADB recovery after reboot, adbd restart, debugging timeout, or
  user revocation.
- No product permission to route camera frames, H.264 payloads, meshes, depth,
  or controller state through command JSON.
- No proof that OpenXR tracking or renderer adoption works in a native app.
- No ability to attach a layer after `xrCreateInstance`, install a privileged
  system layer, or inject a layer into an arbitrary installed XR app.

## OpenXR API-Layer Client Boundary

An API layer runs in the target XR app's loader call chain. Termux may send
accepted low-rate typed state through authenticated localhost or another
explicit app adapter; it does not own the layer, OpenXR session, frame loop,
semantic action, or command authority. Require an explicit synthetic-input
release path and app-visible readback.

Use the canonical Meta Quest workflow
[`openxr-tracking-boundary.md`](https://github.com/MesmerPrism/meta-quest-agent-workflow/blob/main/docs/openxr-tracking-boundary.md)
for Android packaging, capability, and limitation details.

## Loopback ADB Gate

Inside Termux:

```sh
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
mkdir -p "$TMPDIR"
adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 shell id
```

Pass condition:

```text
uid=2000(shell)
```

If this gate fails, stop. Termux does not have ADB shell authority, so it
should not install, launch, run logcat, keep awake, or mutate packages.

## On-Device APK Toolchain

Install public packages from Termux repositories:

```sh
pkg update
pkg install android-tools openjdk-17 aapt2 d8 apksigner rust cmake ninja clang make git
```

AAPT2 and `javac` need an Android platform jar. Keep it outside git:

```sh
export ANDROID_JAR="$HOME/quest-lab/android-sdk/platforms/android-33/android.jar"
```

Stage APK artifacts where Termux can read them, preferably in Termux-private
storage:

```text
$HOME/quest-lab/apks
```

Do not assume public shared storage is readable from every Termux execution
context.

## Keep-Awake Discipline

A keep-awake loop is a temporary lab helper. It must be started intentionally,
must have a stop file, and must not be installed as a hidden boot service.

It can refresh an existing ADB shell lease and keep a headset awake during an
attended run. It cannot create ADB authority and should not be treated as a
production process manager.

## Public Evidence

Publish:

- sidecar tool categories;
- ADB gate pass/blocked status;
- whether a smoke panel became visible;
- whether a protected prompt or controller requirement appeared;
- cleanup attempted and result.

Keep private:

- raw logs;
- endpoint values;
- serials;
- screenshots;
- generated APKs and signing artifacts;
- exact local run roots.
